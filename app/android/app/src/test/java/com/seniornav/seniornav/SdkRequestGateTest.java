package com.seniornav.seniornav;

/** Runs with javac/java only; no device, Android SDK calls, credentials or network. */
public final class SdkRequestGateTest {
    public static void main(String[] args) {
        SdkRequestGate gate = new SdkRequestGate();
        long first = gate.begin();
        check(first != 0 && gate.begin() == 0, "second concurrent request rejected");
        // The Dart session locks down, and native still waits for the actual completion.
        check("SESSION_BLOCKED".equals(gate.onUiTimeout(first)) && gate.begin() == 0,
                "UI timeout blocks Dart session without freeing the native slot");
        check(gate.complete(first, true), "real completion releases slot");
        long second = gate.begin();
        check(second > first, "request tokens are unique");
        check(!gate.complete(first, true) && gate.begin() == 0,
                "duplicate/late old completion cannot release new request");
        check(gate.complete(second, true), "second real completion accepted");

        SdkRequestGate timeout = new SdkRequestGate();
        long pending = timeout.begin();
        check(timeout.complete(pending, false) && timeout.begin() == 0,
                "SDK timeout quarantines uncertain server slot");

        SdkRequestGate rejected = new SdkRequestGate();
        long refused = rejected.begin();
        rejected.quarantine(refused);
        rejected.complete(refused, true);
        check(rejected.begin() == 0, "false dispatch plus late callback never restarts queue");
        System.out.println("SdkRequestGate: 8 assertions passed; no network used.");
    }

    private static void check(boolean ok, String description) {
        if (!ok) throw new AssertionError(description);
    }
}
