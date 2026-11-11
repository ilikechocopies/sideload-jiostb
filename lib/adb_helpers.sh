#!/usr/bin/env bash
# Shared ADB package-removal and Shevery permission helpers for stage1.sh and jhs/jhs_stage1.sh.
# Expects callers to define: adb_sh(), log(), warn().

pkg_installed_for_user() {
    local out
    out=$(adb_sh "pm list packages $1" | tr -d '\r' || true)
    printf '%s\n' "$out" | grep -Fx "package:$1" >/dev/null 2>&1
}

pkg_present_on_device() {
    local out
    out=$(adb_sh "pm list packages -u $1" | tr -d '\r' || true)
    printf '%s\n' "$out" | grep -Fx "package:$1" >/dev/null 2>&1
}

# Completely delete a package (including user data); fall back to disabling if protected
remove_or_disable_pkg() {
    local pkg="$1"
    local show_missing="${2:-false}"

    if ! pkg_installed_for_user "$pkg" && ! pkg_present_on_device "$pkg"; then
        [ "$show_missing" = true ] && log "$pkg — not present on device (skipped)"
        return 0
    fi

    adb_sh "am force-stop $pkg" >/dev/null 2>&1 || true
    adb_sh "pm clear $pkg" >/dev/null 2>&1 || true

    if ! pkg_installed_for_user "$pkg"; then
        adb_sh "pm uninstall $pkg" >/dev/null 2>&1 || true
        log "$pkg — already deleted/uninstalled"
        return 0
    fi

    # First try full uninstall (removes user apps or system app updates in /data)
    adb_sh "pm uninstall $pkg" >/dev/null 2>&1 || true

    # If still installed for user 0 (system partition APK), uninstall for user 0 without -k
    if pkg_installed_for_user "$pkg"; then
        adb_sh "pm uninstall --user 0 $pkg" >/dev/null 2>&1 || true
    fi

    if ! pkg_installed_for_user "$pkg"; then
        log "$pkg — completely deleted"
        return 0
    fi

    # Deletion failed (protected system package) — disable and restrict background execution
    adb_sh "cmd appops set $pkg RUN_IN_BACKGROUND ignore" >/dev/null 2>&1 || true
    adb_sh "cmd appops set $pkg RUN_ANY_IN_BACKGROUND ignore" >/dev/null 2>&1 || true
    local dis_out
    dis_out=$(adb_sh "pm disable-user --user 0 $pkg" | tr -d '\r' || true)
    if echo "$dis_out" | grep -qiE "disabled|new state" || \
       adb_sh "pm list packages -d $pkg" | tr -d '\r' | grep -Fx "package:$pkg" >/dev/null 2>&1; then
        log "$pkg — could not be deleted, disabled instead"
    else
        adb_sh "pm suspend --user 0 $pkg" >/dev/null 2>&1 || true
        adb_sh "pm hide $pkg" >/dev/null 2>&1 || true
        warn "$pkg — could not be deleted; attempted disable/suspend (${dis_out:-no output})"
    fi
}

# Grant all runtime/privileged permissions, AppOps, and battery whitelist to Shevery/Shizuku
grant_shevery_permissions() {
    local pkg="$1"
    local perm op pkg_dump

    for perm in \
        android.permission.WRITE_SECURE_SETTINGS \
        android.permission.PACKAGE_USAGE_STATS \
        android.permission.DUMP \
        android.permission.POST_NOTIFICATIONS \
        android.permission.NEARBY_WIFI_DEVICES \
        android.permission.ACCESS_LOCAL_NETWORK \
        android.permission.ACCESS_FINE_LOCATION \
        android.permission.ACCESS_COARSE_LOCATION \
        android.permission.INTERACT_ACROSS_USERS_FULL
    do
        adb_sh "pm grant $pkg $perm" >/dev/null 2>&1 || true
    done

    for op in \
        GET_USAGE_STATS \
        WRITE_SETTINGS \
        REQUEST_INSTALL_PACKAGES \
        SYSTEM_ALERT_WINDOW \
        ACCESS_RESTRICTED_SETTINGS \
        RUN_IN_BACKGROUND \
        RUN_ANY_IN_BACKGROUND \
        START_FOREGROUND \
        POST_NOTIFICATION \
        SYSTEM_EXEMPT_FROM_SUSPENSION \
        SYSTEM_EXEMPT_FROM_HIBERNATION
    do
        adb_sh "cmd appops set $pkg $op allow" >/dev/null 2>&1 || true
    done

    adb_sh "dumpsys deviceidle whitelist +$pkg" >/dev/null 2>&1 || true
    adb_sh "cmd deviceidle whitelist +$pkg" >/dev/null 2>&1 || true
    adb_sh "am set-standby-bucket $pkg active" >/dev/null 2>&1 || true

    pkg_dump=$(adb_sh "dumpsys package $pkg" | tr -d '\r' || true)
    if printf '%s\n' "$pkg_dump" | grep -F "WRITE_SECURE_SETTINGS: granted=true" >/dev/null 2>&1; then
        log "$pkg — all permissions, AppOps & battery whitelist granted (WRITE_SECURE_SETTINGS verified)"
    else
        warn "$pkg — permissions & AppOps applied (could not verify WRITE_SECURE_SETTINGS)"
    fi
}

