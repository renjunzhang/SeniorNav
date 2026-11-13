package com.seniornav.seniornav

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import com.baidu.mapapi.CoordType
import com.baidu.mapapi.RequestAuthResultListener
import com.baidu.mapapi.SDKInitializer
import com.baidu.mapapi.model.LatLng
import com.baidu.mapapi.search.core.PoiDetailInfo
import com.baidu.mapapi.search.core.PoiInfo
import com.baidu.mapapi.search.core.SearchResult
import com.baidu.mapapi.search.poi.*
import com.baidu.mapapi.search.route.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/** The process singleton keeps the gate alive even if Flutter/Activity is recreated. */
internal object BaiduBridge {
    private val main = Handler(Looper.getMainLooper())
    private val gate = SdkRequestGate()
    private var initializing = false
    private var initialized = false
    private var authorized = false
    private var ready = false
    private var initFailed = false
    private var initExpired = false
    private val initReplies = mutableListOf<Reply>()
    private var active: Request? = null

    private class Reply(val owner: Any, var result: MethodChannel.Result?) {
        fun success(value: Any?) { result?.success(value); result = null }
        fun fail(code: String, text: String) { result?.error(code, text, null); result = null }
    }

    private class Request(val token: Long, val reply: Reply) {
        var destroy: () -> Unit = {}
        lateinit var deadline: Runnable
    }

    fun detach(owner: Any) {
        initReplies.removeAll { it.owner === owner }
        if (active?.reply?.owner === owner) active?.reply?.result = null
        // Do not cancel the SDK search or release its gate: the server may still be busy.
    }

    fun handle(context: Context, owner: Any, call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(owner, result)
        try {
            when (call.method) {
                "initialize" -> initialize(context.applicationContext, call.argument<Boolean>("privacyAccepted") == true, reply)
                "getBaiduVersion" -> {
                    val version = try {
                        @Suppress("DEPRECATION")
                        context.packageManager.getPackageInfo("com.baidu.BaiduMap", 0).versionName
                    } catch (_: PackageManager.NameNotFoundException) { null }
                    reply.success(version)
                }
                "transit", "walking" -> route(call, reply)
                "searchPoi" -> searchPoi(call, reply)
                "poiDetail" -> poiDetail(call, reply)
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            reply.fail("INVALID_ARGUMENTS", "地点信息不完整，请让家人重新设置")
        } catch (_: Exception) {
            // SDK exceptions may contain credentials/coordinates. Never send exception.toString().
            active?.takeIf { it.reply === reply }?.let { gate.quarantine(it.token) }
            reply.fail("SDK_UNAVAILABLE", "路线服务暂不可用，请打开百度地图")
        }
    }

    private fun initialize(context: Context, consent: Boolean, reply: Reply) {
        if (!consent) {
            reply.fail("PRIVACY_REQUIRED", "请先阅读并同意位置与地图服务说明")
            return
        }
        if (ready) { reply.success(null); return }
        if (initFailed) { reply.fail("SDK_UNAVAILABLE", "路线服务暂不可用，请打开百度地图"); return }
        if (initializing && initExpired) {
            reply.fail("SDK_TIMEOUT", "地图服务仍在准备，请先打开百度地图")
            return
        }
        initReplies.add(reply)
        if (initializing) return
        initializing = true
        val key = try {
            @Suppress("DEPRECATION")
            context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                .metaData?.getString("com.baidu.lbsapi.API_KEY")
        } catch (_: Exception) { null }
        if (key.isNullOrBlank()) { failInitialization(); return }
        try {
            SDKInitializer.addAuthResultListener(authListener)
            SDKInitializer.setAgreePrivacy(context, true)
            SDKInitializer.setCoordType(CoordType.BD09LL)
            SDKInitializer.initialize(context) {
                main.post { initialized = true; finishInitialization() }
            }
        } catch (_: Exception) {
            failInitialization()
            return
        }
        // UI can stop waiting, but this never calls initialize a second time.
        main.postDelayed({
            if (!ready && !initFailed) {
                initExpired = true
                initReplies.forEach { it.fail("SDK_TIMEOUT", "地图服务仍在准备，请稍后再试或打开百度地图") }
                initReplies.clear()
            }
        }, 30_000)
    }

    private val authListener = RequestAuthResultListener { status, _ ->
        main.post {
            if (!initFailed) {
                if (status == 0) { authorized = true; finishInitialization() }
                else failInitialization()
            }
        }
    }

    private fun failInitialization() {
        initFailed = true
        initReplies.forEach { it.fail("AUTH_FAILED", "地图服务暂不可用，请打开百度地图") }
        initReplies.clear()
        SDKInitializer.removeAuthResultListener(authListener)
    }

    private fun finishInitialization() {
        if (!initialized || !authorized || initFailed || ready) return
        ready = true
        SDKInitializer.removeAuthResultListener(authListener)
        initReplies.forEach { it.success(null) }
        initReplies.clear()
    }

    private fun begin(reply: Reply): Request? {
        if (!ready) { reply.fail("SDK_NOT_READY", "地图服务尚未准备好，请稍后再试"); return null }
        val token = gate.begin()
        if (token == 0L) {
            reply.fail(if (gate.isQuarantined) "SESSION_BLOCKED" else "BUSY", "上一项查询尚未安全结束，请先打开百度地图")
            return null
        }
        return Request(token, reply).also { request ->
            active = request
            request.deadline = Runnable {
                gate.onUiTimeout(token)?.let { code ->
                    reply.fail(code, "查询仍未结束，请打开百度地图")
                    // Keep both the request and process-wide gate until an actual callback.
                }
            }
            main.postDelayed(request.deadline, 30_000)
        }
    }

    private fun dispatched(request: Request, accepted: Boolean) {
        if (accepted) return
        gate.quarantine(request.token)
        request.reply.fail("SESSION_BLOCKED", "查询未能发起，请打开百度地图")
        // false may still deliver a callback. Keep the search alive and do not retry.
    }

    private fun completed(request: Request, error: SearchResult.ERRORNO?, produce: () -> Any?) {
        // Always post: dispatch's boolean result must be known before a synchronous callback runs.
        main.post {
            if (!gate.isCurrent(request.token)) return@post
            val completionKnown = error != SearchResult.ERRORNO.NETWORK_TIME_OUT &&
                    error != SearchResult.ERRORNO.NETWORK_ERROR
            main.removeCallbacks(request.deadline)
            try {
                if (!completionKnown) request.reply.fail("SESSION_BLOCKED", "网络不稳定，请打开百度地图")
                else request.reply.success(produce())
            } catch (_: MissingPoi) {
                request.reply.fail("POI_NOT_FOUND", "暂时找不到这个地点，请换个名称搜索")
            } catch (_: SdkFailure) {
                request.reply.fail("SDK_QUERY_FAILED", "暂时查不到结果，请稍后再试或打开百度地图")
            } catch (_: Exception) {
                request.reply.fail("SDK_RESPONSE_INVALID", "路线信息暂时无法读取，请打开百度地图")
            } finally {
                runCatching { request.destroy() }
                gate.complete(request.token, completionKnown)
                if (active === request) active = null
            }
        }
    }

    private fun route(call: MethodCall, reply: Reply) {
        val from = point(call, "from")
        val to = point(call, "to")
        val policy = call.argument<Number>("policy")?.toInt() ?: 0
        require(policy == 0 || policy == 1 || policy == 3 || policy == 5)
        val request = begin(reply) ?: return
        val search = RoutePlanSearch.newInstance()
        request.destroy = { search.destroy() }
        search.setOnGetRoutePlanResultListener(object : OnGetRoutePlanResultListener {
            override fun onGetMassTransitRouteResult(response: MassTransitRouteResult) {
                if (call.method == "transit") completed(request, response.error) {
                    routePayload(response.error) { transitRoutes(response) }.toString()
                }
            }
            override fun onGetWalkingRouteResult(response: WalkingRouteResult) {
                if (call.method == "walking") completed(request, response.error) {
                    routePayload(response.error) { walkingRoutes(response) }.toString()
                }
            }
            override fun onGetTransitRouteResult(r: TransitRouteResult) = Unit
            override fun onGetDrivingRouteResult(r: DrivingRouteResult) = Unit
            override fun onGetIndoorRouteResult(r: IndoorRouteResult) = Unit
            override fun onGetBikingRouteResult(r: BikingRouteResult) = Unit
            override fun onGetIntegralRouteResult(r: IntegralRouteResult) = Unit
        })
        val ok = if (call.method == "transit") {
            // SDK policy values differ from Android URI sy (no subway=4, subway first=6).
            val tactics = when (policy) {
                1 -> MassTransitRoutePlanOption.TacticsIncity.ETRANS_LEAST_TRANSFER
                3 -> MassTransitRoutePlanOption.TacticsIncity.ETRANS_NO_SUBWAY
                5 -> MassTransitRoutePlanOption.TacticsIncity.ETRANS_SUBWAY_FIRST
                else -> MassTransitRoutePlanOption.TacticsIncity.ETRANS_SUGGEST
            }
            search.masstransitSearch(MassTransitRoutePlanOption().from(PlanNode.withLocation(from))
                .to(PlanNode.withLocation(to)).coordType("bd09ll").tacticsIncity(tactics))
        } else {
            search.walkingSearch(WalkingRoutePlanOption().from(PlanNode.withLocation(from)).to(PlanNode.withLocation(to)))
        }
        dispatched(request, ok)
    }

    private fun point(call: MethodCall, prefix: String): LatLng {
        val lat = call.argument<Number>("${prefix}Lat")?.toDouble() ?: throw IllegalArgumentException()
        val lng = call.argument<Number>("${prefix}Lng")?.toDouble() ?: throw IllegalArgumentException()
        require(lat.isFinite() && lng.isFinite() && lat in -90.0..90.0 && lng in -180.0..180.0)
        return LatLng(lat, lng)
    }

    private fun routePayload(error: SearchResult.ERRORNO?, routes: () -> JSONArray): JSONObject {
        val empty = error == SearchResult.ERRORNO.RESULT_NOT_FOUND || error == SearchResult.ERRORNO.ST_EN_TOO_NEAR
        if (error != SearchResult.ERRORNO.NO_ERROR && !empty) {
            return JSONObject().put("status", -1).put("message", "SDK error: ${error?.name ?: "UNKNOWN"}")
        }
        return JSONObject().put("status", 0)
            .put("result", JSONObject().put("routes", if (empty) JSONArray() else routes()))
            .put("sdkError", error.name)
    }

    private fun transitRoutes(response: MassTransitRouteResult): JSONArray {
        val routes = JSONArray()
        for (line in response.routeLines.orEmpty()) {
            val groups = JSONArray()
            for (group in line.newSteps.orEmpty()) {
                val segments = JSONArray()
                for (step in group) {
                    val bus = step.busInfo
                    val kind = step.vehileType
                    val otherVehicle = step.trainInfo != null || step.planeInfo != null || step.coachInfo != null
                    val walkingOrTransfer = !otherVehicle && bus == null &&
                        (kind == MassTransitRouteLine.TransitStep.StepVehicleInfoType.ESTEP_WALK || kind == null) &&
                        (step.transType == 0 || step.transType == 3 || step.transType == 4)
                    val vehicle = JSONObject().put("type", kind?.getInt() ?: -1)
                    val detail: Any = when {
                        bus != null && !otherVehicle -> JSONObject()
                            .put("name", text(bus.name)).put("type", bus.type)
                            .put("direct_text", text(bus.directText))
                            .put("on_station", text(bus.departureStation)).put("off_station", text(bus.arriveStation))
                            .put("stop_num", bus.stopNum)
                            // These SDK times describe first/last service, not trip arrival.
                            .put("first_time", text(bus.departureTime)).put("last_time", text(bus.arriveTime))
                        walkingOrTransfer -> JSONObject.NULL
                        // Keep unsupported/malformed riding segments visible to Dart's classifier.
                        // A null detail would silently erase trains/coaches/planes and could make
                        // a mixed route appear to be entirely bus or metro.
                        else -> JSONObject().put("type", -1).put("name", JSONObject.NULL)
                    }
                    vehicle.put("detail", detail)
                    segments.put(JSONObject().put("trans_type", step.transType).put("distance", step.distance)
                        .put("instructions", text(step.instructions)).put("vehicle_info", vehicle))
                }
                groups.put(segments)
            }
            routes.put(JSONObject().put("duration", line.duration).put("distance", line.distance)
                .put("arrive_time", text(line.arriveTime)).put("steps", groups))
        }
        return routes
    }

    private fun walkingRoutes(response: WalkingRouteResult): JSONArray {
        val routes = JSONArray()
        for (line in response.routeLines.orEmpty()) {
            val steps = JSONArray()
            for (step in line.allStep.orEmpty()) {
                steps.put(JSONObject().put("distance", step.distance).put("instructions", text(step.instructions)))
            }
            routes.put(JSONObject().put("duration", line.duration).put("distance", line.distance).put("steps", steps))
        }
        return routes
    }

    private fun text(value: String?): Any = value?.takeIf { it.isNotBlank() } ?: JSONObject.NULL

    private fun searchPoi(call: MethodCall, reply: Reply) {
        val query = call.argument<String>("query")?.trim().orEmpty()
        val city = call.argument<String>("city")?.trim().orEmpty()
        require(query.isNotEmpty() && city.isNotEmpty() && query.length <= 100 && city.length <= 60)
        val request = begin(reply) ?: return
        val search = PoiSearch.newInstance()
        request.destroy = { search.destroy() }
        search.setOnGetPoiSearchResultListener(object : PoiListener() {
            override fun onGetPoiResult(response: PoiResult) {
                completed(request, response.error) {
                    if (response.error == SearchResult.ERRORNO.RESULT_NOT_FOUND) emptyList<Map<String, Any?>>()
                    else {
                        if (response.error != SearchResult.ERRORNO.NO_ERROR) throw SdkFailure()
                        response.allPoi.orEmpty().mapNotNull { poiMap(it, city) }
                    }
                }
            }
        })
        dispatched(request, search.searchInCity(PoiCitySearchOption().city(city).keyword(query)
            .cityLimit(true).scope(2).pageNum(0).pageCapacity(10)))
    }

    private fun poiDetail(call: MethodCall, reply: Reply) {
        val uid = call.argument<String>("uid")?.trim().orEmpty()
        require(uid.isNotEmpty() && uid.length <= 100)
        val request = begin(reply) ?: return
        val search = PoiSearch.newInstance()
        request.destroy = { search.destroy() }
        search.setOnGetPoiSearchResultListener(object : PoiListener() {
            override fun onGetPoiDetailResult(response: PoiDetailSearchResult) {
                completed(request, response.error) {
                    if (response.error == SearchResult.ERRORNO.RESULT_NOT_FOUND) throw MissingPoi()
                    if (response.error != SearchResult.ERRORNO.NO_ERROR) throw SdkFailure()
                    val detail = response.poiDetailInfoList.orEmpty().firstOrNull { it.uid == uid }
                        ?: throw MissingPoi()
                    detailMap(detail) ?: throw MissingPoi()
                }
            }
        })
        // Plural option deliberately selects the rich PoiDetailSearchResult callback (naviLocation).
        dispatched(request, search.searchPoiDetail(PoiDetailSearchOption().poiUids(uid)))
    }

    private fun poiMap(poi: PoiInfo, fallbackCity: String): Map<String, Any?>? {
        val location = poi.location ?: return null
        if (poi.uid.isNullOrBlank() || poi.name.isNullOrBlank()) return null
        return mapOf("uid" to poi.uid, "name" to poi.name, "address" to (poi.address ?: ""),
            "city" to (poi.city?.takeIf { it.isNotBlank() } ?: fallbackCity),
            "latitude" to location.latitude, "longitude" to location.longitude)
    }

    private fun detailMap(poi: PoiDetailInfo): Map<String, Any?>? {
        val location = poi.location ?: return null
        if (poi.uid.isNullOrBlank() || poi.name.isNullOrBlank()) return null
        val map = mutableMapOf<String, Any?>("uid" to poi.uid, "name" to poi.name,
            "address" to (poi.address ?: ""), "city" to (poi.city ?: ""),
            "latitude" to location.latitude, "longitude" to location.longitude)
        poi.naviLocation?.let { map["naviLatitude"] = it.latitude; map["naviLongitude"] = it.longitude }
        return map
    }

    private open class PoiListener : OnGetPoiSearchResultListener {
        override fun onGetPoiResult(r: PoiResult) = Unit
        override fun onGetPoiDetailResult(r: PoiDetailResult) = Unit
        override fun onGetPoiDetailResult(r: PoiDetailSearchResult) = Unit
        override fun onGetPoiIndoorResult(r: PoiIndoorResult) = Unit
    }
    private class MissingPoi : RuntimeException()
    private class SdkFailure : RuntimeException()
}
