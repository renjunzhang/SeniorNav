package com.seniornav.seniornav;

/** Process-wide callers share one instance. A UI timeout must not call complete(). */
final class SdkRequestGate {
    private long nextToken = 1;
    private long activeToken;
    private boolean quarantined;

    synchronized long begin() {
        if (activeToken != 0 || quarantined) return 0;
        activeToken = nextToken++;
        return activeToken;
    }

    synchronized boolean isCurrent(long token) {
        return token != 0 && activeToken == token;
    }

    synchronized boolean complete(long token, boolean serverCompletionKnown) {
        if (!isCurrent(token)) return false;
        if (!serverCompletionKnown) quarantined = true;
        activeToken = 0;
        return true;
    }

    synchronized void quarantine(long token) {
        if (isCurrent(token)) quarantined = true;
    }

    synchronized String onUiTimeout(long token) {
        // Dart must stop this session, while native still waits for the real completion.
        return isCurrent(token) ? "SESSION_BLOCKED" : null;
    }

    synchronized boolean isQuarantined() {
        return quarantined;
    }
}
