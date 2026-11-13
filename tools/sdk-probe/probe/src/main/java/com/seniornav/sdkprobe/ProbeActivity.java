package com.seniornav.sdkprobe;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import com.baidu.mapapi.SDKInitializer;
import com.baidu.mapapi.RequestAuthResultListener;
import com.baidu.mapapi.model.LatLng;
import com.baidu.mapapi.search.core.BusInfo;
import com.baidu.mapapi.search.core.SearchResult;
import com.baidu.mapapi.search.route.MassTransitRouteLine;
import com.baidu.mapapi.search.route.MassTransitRoutePlanOption;
import com.baidu.mapapi.search.route.MassTransitRouteResult;
import com.baidu.mapapi.search.route.OnGetRoutePlanResultListener;
import com.baidu.mapapi.search.route.PlanNode;
import com.baidu.mapapi.search.route.RoutePlanSearch;
import com.baidu.mapapi.search.route.WalkingRouteLine;
import com.baidu.mapapi.search.route.WalkingRoutePlanOption;
import com.baidu.mapapi.search.route.WalkingRouteResult;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * M0 最小运行时探针：只验证 Search SDK 的公交/步行检索、字段完整性与延迟。
 *
 * 输出刻意序列化成 Web API 的 JSON 形状（vehicle_info.detail.direct_text 等），
 * 这样 app/lib/baidu_route_parser.dart 可以原样消费，字段完整性用现有解析器判定，
 * 不另写一套映射。详见 tools/sdk-probe/README.md。
 *
 * 起终点是公共地标，三条 OD 与 app/test/fixtures/ 里录制的完全一致，
 * 这样 SDK 与 Web API 的结果可以逐条对照。不含任何私人位置。
 */
public class ProbeActivity extends Activity {
    private static final String TAG = "SDKPROBE";

    /** 与 fixtures 同名的三条 OD：地铁直达、公交换乘、95 米短途（预期无公交方案）。 */
    private static final Od[] CASES = {
            new Od("metro_direct", 31.804835, 117.297095, 31.891171, 117.323703),
            new Od("bus_transfer", 31.847342, 117.177405, 31.863345, 117.297176),
            new Od("walk_short", 31.803746, 117.297401, 31.804835, 117.297095),
    };

    private static final class Od {
        final String id;
        final LatLng from;
        final LatLng to;

        Od(String id, double fromLat, double fromLng, double toLat, double toLng) {
            this.id = id;
            this.from = new LatLng(fromLat, fromLng);
            this.to = new LatLng(toLat, toLng);
        }
    }

    private RoutePlanSearch search;
    private int caseIndex;
    private boolean walkingPhase;
    private long startMs;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private boolean sdkReady;
    private boolean authorized;
    private boolean started;
    private boolean halted;
    // 同一进程内 Activity 重建也不能静默再跑一轮；新实验须显式 force-stop 后启动。
    private static boolean runClaimed;

    private final RequestAuthResultListener authListener = (status, message) ->
            mainHandler.post(() -> {
                if (isDestroyed() || isFinishing() || halted) return;
                // 不输出 message，它可能包含鉴权凭据/设备标识。
                Log.i(TAG, "鉴权状态=" + status);
                if (status != 0) {
                    halted = true;
                    Log.e(TAG, "鉴权未成功，停止本轮；不发起路线检索、不自动重试。");
                    return;
                }
                authorized = true;
                startWhenReady();
            });

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (configuredAk().isEmpty()) {
            Log.e(TAG, "AK 未配置。构建时传 -PbaiduAk=… 或环境变量 BAIDU_ANDROID_AK。");
            finish();
            return;
        }
        if (runClaimed) {
            Log.w(TAG, "本进程已启动过一轮，禁止 Activity 重建自动重跑。");
            finish();
            return;
        }
        // 官方硬门槛：ApplicationContext；同意隐私在 initialize 之前。
        SDKInitializer.setAgreePrivacy(getApplicationContext(), true);
        SDKInitializer.addAuthResultListener(authListener);
        Log.i(TAG, "等待 SDK 初始化与鉴权完成；尚未发起路线检索。");
        SDKInitializer.initialize(getApplicationContext(), () -> mainHandler.post(() -> {
            if (isDestroyed() || isFinishing() || halted) return;
            sdkReady = true;
            startWhenReady();
        }));
    }

    private void startWhenReady() {
        if (!sdkReady || !authorized || started || halted || runClaimed) return;
        started = true;
        runClaimed = true;
        search = RoutePlanSearch.newInstance();
        search.setOnGetRoutePlanResultListener(listener);
        startNext();
    }

    /** 一律串行：上一条回调里才发下一条（ADR 0002 A8，并发上限 3）。 */
    private void startNext() {
        if (caseIndex >= CASES.length) {
            Log.i(TAG, "DONE。共 " + CASES.length * 2 + " 次请求，adb pull 见 README。");
            search.destroy();
            search = null;
            return;
        }
        Od od = CASES[caseIndex];
        startMs = SystemClock.elapsedRealtime();
        boolean ok;
        if (walkingPhase) {
            ok = search.walkingSearch(new WalkingRoutePlanOption()
                    .from(PlanNode.withLocation(od.from))
                    .to(PlanNode.withLocation(od.to)));
        } else {
            ok = search.masstransitSearch(new MassTransitRoutePlanOption()
                    .from(PlanNode.withLocation(od.from))
                    .to(PlanNode.withLocation(od.to))
                    .coordType("bd09ll"));
        }
        Log.i(TAG, od.id + (walkingPhase ? " walking" : " transit") + " 发起=" + ok);
        if (!ok) {
            // 不自动跳到下一条：无法确定 SDK 是否还会回调，跳了会重复推进队列。
            halted = true;
            Log.e(TAG, "发起失败，队列停在此处；迟到回调只记录，不推进、不自动重试。");
        }
    }

    private void advance() {
        if (halted || isDestroyed() || isFinishing()) return;
        if (walkingPhase) {
            walkingPhase = false;
            caseIndex++;
        } else {
            walkingPhase = true;
        }
        startNext();
    }

    private String configuredAk() {
        try {
            ApplicationInfo ai = getPackageManager()
                    .getApplicationInfo(getPackageName(), PackageManager.GET_META_DATA);
            String ak = ai.metaData == null ? null : ai.metaData.getString("com.baidu.lbsapi.API_KEY");
            return ak == null ? "" : ak;
        } catch (PackageManager.NameNotFoundException e) {
            return "";
        }
    }

    private final OnGetRoutePlanResultListener listener = new OnGetRoutePlanResultListener() {
        @Override
        public void onGetMassTransitRouteResult(MassTransitRouteResult result) {
            mainHandler.post(() -> {
                if (isDestroyed() || isFinishing() || walkingPhase || caseIndex >= CASES.length) return;
                Od od = CASES[caseIndex];
                long ms = SystemClock.elapsedRealtime() - startMs;
                Log.i(TAG, od.id + " transit 延迟=" + ms + "ms error=" + result.error);
                JSONObject dump = result.error == SearchResult.ERRORNO.NO_ERROR
                        ? transitDump(result)
                        : rejected(String.valueOf(result.error));
                write("sdk_probe_" + od.id + "_transit.json", dump);
                logTransitCompleteness(od.id, result);
                advance();
            });
        }

        @Override
        public void onGetWalkingRouteResult(WalkingRouteResult result) {
            mainHandler.post(() -> {
                if (isDestroyed() || isFinishing() || !walkingPhase || caseIndex >= CASES.length) return;
                Od od = CASES[caseIndex];
                long ms = SystemClock.elapsedRealtime() - startMs;
                Log.i(TAG, od.id + " walking 延迟=" + ms + "ms error=" + result.error);
                JSONObject dump = result.error == SearchResult.ERRORNO.NO_ERROR
                        ? walkingDump(result)
                        : rejected(String.valueOf(result.error));
                write("sdk_probe_" + od.id + "_walking.json", dump);
                advance();
            });
        }

        @Override public void onGetTransitRouteResult(com.baidu.mapapi.search.route.TransitRouteResult r) { }
        @Override public void onGetDrivingRouteResult(com.baidu.mapapi.search.route.DrivingRouteResult r) { }
        @Override public void onGetIndoorRouteResult(com.baidu.mapapi.search.route.IndoorRouteResult r) { }
        @Override public void onGetBikingRouteResult(com.baidu.mapapi.search.route.BikingRouteResult r) { }
        @Override public void onGetIntegralRouteResult(com.baidu.mapapi.search.route.IntegralRouteResult r) { }
    };

    /** SDK 侧错误。status=-1 是探针自定义的标记，不是百度的状态码。 */
    private JSONObject rejected(String error) {
        JSONObject o = new JSONObject();
        try {
            o.put("status", -1);
            o.put("message", "SDK error: " + error);
        } catch (Exception ignored) {
        }
        return o;
    }

    private JSONObject transitDump(MassTransitRouteResult result) {
        JSONObject root = new JSONObject();
        try {
            root.put("status", 0);
            JSONObject res = new JSONObject();
            JSONArray routes = new JSONArray();
            List<MassTransitRouteLine> lines = result.getRouteLines();
            if (lines != null) {
                for (MassTransitRouteLine line : lines) {
                    JSONObject route = new JSONObject();
                    route.put("duration", line.getDuration());
                    route.put("distance", line.getDistance());
                    route.put("arrive_time", nullToNull(line.getArriveTime()));
                    JSONArray groups = new JSONArray();
                    List<List<MassTransitRouteLine.TransitStep>> newSteps = line.getNewSteps();
                    if (newSteps != null) {
                        for (List<MassTransitRouteLine.TransitStep> group : newSteps) {
                            JSONArray segs = new JSONArray();
                            for (MassTransitRouteLine.TransitStep step : group) {
                                segs.put(transitSegment(step));
                            }
                            groups.put(segs);
                        }
                    }
                    route.put("steps", groups);
                    routes.put(route);
                }
            }
            res.put("routes", routes);
            root.put("result", res);
        } catch (Exception e) {
            Log.e(TAG, "transit 序列化失败", e);
        }
        return root;
    }

    private JSONObject transitSegment(MassTransitRouteLine.TransitStep step) throws Exception {
        JSONObject seg = new JSONObject();
        seg.put("trans_type", step.getTransType());
        seg.put("distance", step.getDistance());
        seg.put("instructions", nullToNull(step.getInstructions()));
        JSONObject vi = new JSONObject();
        BusInfo bus = step.getBusInfo();
        if (bus == null) {
            vi.put("type", 5);
            vi.put("detail", JSONObject.NULL);
        } else {
            vi.put("type", 3);
            JSONObject detail = new JSONObject();
            detail.put("name", nullToNull(bus.getName()));
            detail.put("type", bus.getType());
            detail.put("direct_text", nullToNull(bus.getDirectText()));
            detail.put("on_station", nullToNull(bus.getDepartureStation()));
            detail.put("off_station", nullToNull(bus.getArriveStation()));
            detail.put("stop_num", bus.getStopNum());
            // 命名陷阱：TransitBaseInfo 的 departure/arrive 装的是首/末班（ADR 0003）。
            detail.put("first_time", nullToNull(bus.getDepartureTime()));
            detail.put("last_time", nullToNull(bus.getArriveTime()));
            vi.put("detail", detail);
        }
        seg.put("vehicle_info", vi);
        return seg;
    }

    private JSONObject walkingDump(WalkingRouteResult result) {
        JSONObject root = new JSONObject();
        try {
            root.put("status", 0);
            JSONObject res = new JSONObject();
            JSONArray routes = new JSONArray();
            List<WalkingRouteLine> lines = result.getRouteLines();
            if (lines != null) {
                for (WalkingRouteLine line : lines) {
                    JSONObject route = new JSONObject();
                    route.put("duration", line.getDuration());
                    route.put("distance", line.getDistance());
                    JSONArray steps = new JSONArray();
                    List<WalkingRouteLine.WalkingStep> all = line.getAllStep();
                    if (all != null) {
                        for (WalkingRouteLine.WalkingStep step : all) {
                            JSONObject s = new JSONObject();
                            s.put("distance", step.getDistance());
                            s.put("instructions", nullToNull(step.getInstructions()));
                            steps.put(s);
                        }
                    }
                    route.put("steps", steps);
                    routes.put(route);
                }
            }
            res.put("routes", routes);
            root.put("result", res);
        } catch (Exception e) {
            Log.e(TAG, "walking 序列化失败", e);
        }
        return root;
    }

    private void logTransitCompleteness(String id, MassTransitRouteResult result) {
        List<MassTransitRouteLine> lines = result.getRouteLines();
        if (lines == null) {
            Log.w(TAG, id + " 完整性：无路线");
            return;
        }
        int legs = 0;
        int missingDirection = 0;
        int missingStopNum = 0;
        int missingFirstLast = 0;
        for (MassTransitRouteLine line : lines) {
            List<List<MassTransitRouteLine.TransitStep>> groups = line.getNewSteps();
            if (groups == null) continue;
            for (List<MassTransitRouteLine.TransitStep> group : groups) {
                for (MassTransitRouteLine.TransitStep step : group) {
                    BusInfo bus = step.getBusInfo();
                    if (bus == null) continue;
                    legs++;
                    if (isBlank(bus.getDirectText())) missingDirection++;
                    if (bus.getStopNum() <= 0) missingStopNum++;
                    if (isBlank(bus.getDepartureTime()) || isBlank(bus.getArriveTime())) missingFirstLast++;
                }
            }
        }
        Log.i(TAG, id + " 完整性：方案=" + lines.size()
                + " 乘车段=" + legs
                + " 缺direction=" + missingDirection
                + " 缺stopNum=" + missingStopNum
                + " 缺首末班=" + missingFirstLast);
        if (lines.isEmpty()) {
            // 对应 Web API 的 status==0 && routes 为空（ADR 0002 A6）。
            // SDK 用 NO_ERROR + 空列表表达，还是用错误枚举表达，正是要测的点。
            Log.i(TAG, id + " 无公交方案：error=" + result.error + "（记录 SDK 如何表达空结果）");
        }
    }

    private static boolean isBlank(String s) {
        return s == null || s.trim().isEmpty();
    }

    private static Object nullToNull(String s) {
        return isBlank(s) ? JSONObject.NULL : s;
    }

    private void write(String name, JSONObject json) {
        File dir = getExternalFilesDir(null);
        if (dir == null) {
            Log.e(TAG, "外部存储不可用，无法落盘 " + name);
            return;
        }
        File out = new File(dir, name);
        try (FileOutputStream fos = new FileOutputStream(out)) {
            fos.write(json.toString().getBytes(StandardCharsets.UTF_8));
            Log.i(TAG, "已写出 " + out.getAbsolutePath());
        } catch (IOException e) {
            Log.e(TAG, "写盘失败 " + name, e);
        }
    }

    @Override
    protected void onDestroy() {
        halted = true;
        SDKInitializer.removeAuthResultListener(authListener);
        mainHandler.removeCallbacksAndMessages(null);
        if (search != null) search.destroy();
        super.onDestroy();
    }
}
