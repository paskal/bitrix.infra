<?php

// Release drain gate, prepended to every php-fpm request by zz-pm.conf (php_admin_value, so CLI and cron skip it).
// bitrix.infra-private scripts/site-release.sh closes /deploy-gate/<tree>.gate, waits until no request holds
// <tree>.inflight and moves the checkout while no request of that tree runs, so a request never mixes files of two
// commits. A request waits for a closed gate at most 15 s and then runs anyway; without the lock files nothing is gated.
(static function (): void {
    if (!preg_match('~^/web/(prod|dev)/?$~', (string)($_SERVER['DOCUMENT_ROOT'] ?? ''), $tree)) {
        return;
    }
    $gate = @fopen('/deploy-gate/' . $tree[1] . '.gate', 'rb');
    if ($gate === false) {
        return;
    }
    $inflight = @fopen('/deploy-gate/' . $tree[1] . '.inflight', 'rb');
    if ($inflight === false) {
        fclose($gate);
        return;
    }
    $deadline = hrtime(true) + 15_000_000_000;
    while (!flock($gate, LOCK_SH | LOCK_NB)) {
        if (hrtime(true) > $deadline) {
            fclose($gate);
            fclose($inflight);
            return;
        }
        usleep(10000);
    }
    // the release takes .inflight only while it holds .gate, so with the gate open this lock is free
    $held = flock($inflight, LOCK_SH | LOCK_NB);
    fclose($gate);
    if ($held) {
        // held to the end of the request, when PHP closes the handle and drops the lock
        $GLOBALS['__deploy_gate_inflight'] = $inflight;
    } else {
        fclose($inflight);
    }
})();
