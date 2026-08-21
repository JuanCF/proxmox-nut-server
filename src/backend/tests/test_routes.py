from flask import Flask

import routes.history
import routes.hooks
import routes.logs
import routes.system
import routes.ups
import routes.upsmon
import routes.users
import routes.wol
from services import auth_db


def _make_app():
    app = Flask(__name__)
    app.config["TESTING"] = True
    return app


def _register_all(app):
    app.register_blueprint(routes.hooks.hooks_bp)
    app.register_blueprint(routes.logs.logs_bp)
    app.register_blueprint(routes.system.system_bp)
    app.register_blueprint(routes.ups.ups_bp)
    app.register_blueprint(routes.upsmon.upsmon_bp)
    app.register_blueprint(routes.users.users_bp)
    app.register_blueprint(routes.wol.wol_bp)
    app.register_blueprint(routes.history.history_bp)
    return app


def _create_admin_bearer():
    account, _ = auth_db.create_account("admin", "adminpass123", role="admin")
    raw_key, _ = auth_db.create_api_key(account["id"])
    return raw_key


def _create_viewer_bearer():
    account, _ = auth_db.create_account("viewer", "viewerpass123", role="viewer")
    raw_key, _ = auth_db.create_api_key(account["id"])
    return raw_key


# ── Hooks routes ──────────────────────────────────────────────────────

def test_list_hooks_route(monkeypatch):
    monkeypatch.setattr("routes.hooks.list_hooks", lambda n: ["ONLINE"])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/myups")
        assert resp.status_code == 200
        assert resp.get_json()["hooks"] == ["ONLINE"]


def test_list_hooks_route_invalid_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/")
        assert resp.status_code == 404


def test_get_hook_route(monkeypatch):
    monkeypatch.setattr("routes.hooks.get_hook", lambda n, e: "echo hi")
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/myups/ONLINE")
        assert resp.status_code == 200
        assert resp.get_json()["content"] == "echo hi"


def test_get_hook_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.hooks.get_hook", lambda n, e: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/myups/ONLINE")
        assert resp.status_code == 404


def test_put_hook_route(monkeypatch):
    monkeypatch.setattr("routes.hooks.put_hook", lambda n, e, c: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/hooks/myups/ONLINE", json={"content": "echo hi"})
        assert resp.status_code == 200


def test_put_hook_route_validation_error(monkeypatch):
    monkeypatch.setattr("routes.hooks.put_hook", lambda n, e, c: (_ for _ in ()).throw(ValueError("bad")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/hooks/myups/ONLINE", json={"content": ""})
        assert resp.status_code == 400


def test_delete_hook_route(monkeypatch):
    monkeypatch.setattr("routes.hooks.delete_hook", lambda n, e: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/hooks/myups/ONLINE")
        assert resp.status_code == 200


# ── Logs routes ───────────────────────────────────────────────────────

def test_recent_logs(monkeypatch):
    monkeypatch.setattr("routes.logs.run_cmd", lambda cmd, **kw: (0, "log line 1\nlog line 2\n", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/logs/recent")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["returncode"] == 0


def test_recent_logs_syslog_fallback(monkeypatch, tmp_path):
    orig = routes.logs.run_cmd
    log_file = tmp_path / "messages"
    log_file.write_text("syslog line 1\nsyslog line 2\n")

    def fake_run_cmd(cmd, **kw):
        if cmd[0] == "journalctl":
            return (0, "-- No entries --\n", "No journal files were found.\n")
        return orig(cmd, **kw)

    monkeypatch.setattr("routes.logs.SYSLOG_FILE", str(log_file))
    monkeypatch.setattr("routes.logs.run_cmd", fake_run_cmd)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/logs/recent")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["returncode"] == 0
        assert "syslog line 1" in data["stdout"]
        assert "syslog line 2" in data["stdout"]


def test_recent_logs_syslog_fallback_missing_file(monkeypatch):
    monkeypatch.setattr("routes.logs.SYSLOG_FILE", "/nonexistent/nutwatch/messages")
    monkeypatch.setattr(
        "routes.logs.run_cmd",
        lambda cmd, **kw: (0, "-- No entries --\n", "No journal files were found.\n"),
    )
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/logs/recent")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["returncode"] == 0
        assert data["stdout"] == ""


def test_journal_available_false_when_no_journal(monkeypatch):
    monkeypatch.setattr(
        "routes.logs.run_cmd",
        lambda cmd, **kw: (0, "-- No entries --\n", "No journal files were found.\n"),
    )
    assert routes.logs._journal_available() is False


def test_journal_available_true_with_journal(monkeypatch):
    monkeypatch.setattr(
        "routes.logs.run_cmd",
        lambda cmd, **kw: (0, "Jun 01 00:00:00 host upsd[1]: started\n", ""),
    )
    assert routes.logs._journal_available() is True


def test_journal_available_false_when_binary_missing(monkeypatch):
    # utils.run_cmd returns (-1, "", "<error>") when the binary is absent.
    monkeypatch.setattr("routes.logs.run_cmd", lambda cmd, **kw: (-1, "", "journalctl: not found"))
    assert routes.logs._journal_available() is False


def test_recent_command_uses_journalctl_when_available(monkeypatch):
    monkeypatch.setattr("routes.logs._driver_status_units", lambda: ["nut-driver@ups"])
    cmd = routes.logs._recent_command("50", True)
    assert cmd[0] == "journalctl"
    assert "-n" in cmd and "50" in cmd
    for unit in ("nut-server", "nut-monitor", "nut-driver@ups"):
        assert "-u" in cmd and unit in cmd


def test_recent_command_uses_tail_in_fallback(monkeypatch):
    monkeypatch.setattr("routes.logs.SYSLOG_FILE", "/var/log/messages")
    cmd = routes.logs._recent_command("50", False)
    assert cmd == ["tail", "-n", "50", "/var/log/messages"]


def test_stream_command_journal_and_fallback(monkeypatch):
    assert routes.logs._stream_command(True)[0] == "journalctl"
    monkeypatch.setattr("routes.logs.SYSLOG_FILE", "/var/log/messages")
    assert routes.logs._stream_command(False) == ["tail", "-F", "-n", "0", "/var/log/messages"]


# ── System routes ─────────────────────────────────────────────────────

def test_get_config_route(monkeypatch):
    monkeypatch.setattr("routes.system.get_config", lambda f: "content")
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/config/ups.conf")
        assert resp.status_code == 200
        assert resp.data.decode() == "content"


def test_get_config_route_not_allowed():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/config/../../etc/passwd")
        assert resp.status_code == 404


def test_get_config_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.system.get_config", lambda f: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/config/ups.conf")
        assert resp.status_code == 404


def test_put_config_route(monkeypatch):
    monkeypatch.setattr("routes.system.put_config", lambda f, c: True)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/config/upsmon.conf", data="content")
        assert resp.status_code == 200


def test_put_config_route_not_allowed():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/config/evil.conf", data="x")
        assert resp.status_code == 403


def test_put_config_route_upsd_users_forbidden(monkeypatch):
    monkeypatch.setattr("routes.system.put_config", lambda f, c: True)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/config/upsd.users", data="x")
        assert resp.status_code == 403


def test_put_config_route_fail(monkeypatch):
    monkeypatch.setattr("routes.system.put_config", lambda f, c: False)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/config/upsmon.conf", data="x")
        assert resp.status_code == 500


def test_service_action_restart_server(monkeypatch):
    monkeypatch.setattr("routes.system.restart_server", lambda: (0, "ok", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/service/restart-server")
        assert resp.status_code == 200


def test_service_action_unknown():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/service/unknown")
        assert resp.status_code == 400


def test_service_status_detailed(monkeypatch):
    monkeypatch.setattr("routes.system.detailed_service_status", lambda: {"nut-server": {"active": True, "state": "active"}})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/service/status-detailed")
        assert resp.status_code == 200


def test_driver_action_route(monkeypatch):
    monkeypatch.setattr("routes.system.driver_action", lambda n, a: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/driver/myups/start")
        assert resp.status_code == 200


def test_system_resources_route(monkeypatch):
    monkeypatch.setattr("routes.system.get_system_resources", lambda: {
        "cpu_percent": 25.5,
        "memory_percent": 60.2,
        "memory_used_gb": 4.8,
        "memory_total_gb": 8.0,
        "disk_percent": 45.1,
        "disk_free_gb": 110.5,
        "disk_total_gb": 200.0,
    })
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/system/resources")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["cpu_percent"] == 25.5
        assert data["memory_percent"] == 60.2
        assert data["disk_percent"] == 45.1


def test_system_reboot_route_no_auth():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/reboot")
        assert resp.status_code == 403


def test_system_reboot_route_with_auth(monkeypatch):
    monkeypatch.setattr("routes.system.reboot_system", lambda: (0, "", ""))
    raw_key = _create_admin_bearer()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/reboot", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_system_reboot_route_wrong_token():
    _create_admin_bearer()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/reboot", headers={"Authorization": "Bearer wrong"})
        assert resp.status_code == 401


def test_system_shutdown_route_no_auth():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/shutdown")
        assert resp.status_code == 403


def test_system_shutdown_route_with_auth(monkeypatch):
    monkeypatch.setattr("routes.system.shutdown_system", lambda: (0, "", ""))
    raw_key = _create_admin_bearer()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/shutdown", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_system_restart_nutwatch_route_no_auth():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/restart-nutwatch")
        assert resp.status_code == 403


def test_system_restart_nutwatch_route_with_auth(monkeypatch):
    monkeypatch.setattr("routes.system.restart_nutwatch", lambda: (0, "", ""))
    raw_key = _create_admin_bearer()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/restart-nutwatch", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_driver_action_invalid_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/driver//start")
        assert resp.status_code == 404


def test_driver_action_unknown_action():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/driver/myups/unknown")
        assert resp.status_code == 400


# ── UPS routes ────────────────────────────────────────────────────────

def test_list_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.list_ups", lambda: [{"name": "myups", "status": "online"}])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups")
        assert resp.status_code == 200
        assert len(resp.get_json()) == 1


def test_add_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.add_ups", lambda d: ({"name": "newups"}, None))
    monkeypatch.setattr("routes.ups.driver_action", lambda n, a: (0, "", ""))
    monkeypatch.setattr("routes.ups.restart_server", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups", json={"name": "newups", "driver": "usbhid-ups"})
        assert resp.status_code == 201


def test_add_ups_route_no_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups", json={})
        assert resp.status_code == 400


def test_add_ups_route_conflict(monkeypatch):
    monkeypatch.setattr("routes.ups.add_ups", lambda d: (None, "UPS already exists"))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups", json={"name": "dup"})
        assert resp.status_code == 409


def test_add_ups_route_invalid_directives():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups", json={"name": "u", "directives": "not-a-dict"})
        assert resp.status_code == 400


def test_get_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.get_ups", lambda n: {"name": "myups", "status": "online"})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups/myups")
        assert resp.status_code == 200


def test_get_ups_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.ups.get_ups", lambda n: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups/myups")
        assert resp.status_code == 404


def test_get_ups_detail_route(monkeypatch):
    monkeypatch.setattr("routes.ups.get_ups_detail", lambda n: {"battery.charge": 100})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups/myups/detail")
        assert resp.status_code == 200


def test_get_ups_detail_route_fail(monkeypatch):
    monkeypatch.setattr("routes.ups.get_ups_detail", lambda n: (_ for _ in ()).throw(RuntimeError("driver not running")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups/myups/detail")
        assert resp.status_code == 500


def test_edit_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.edit_ups", lambda n, d: {"name": "myups", "desc": "Updated"})
    monkeypatch.setattr("routes.ups.driver_action", lambda n, a: (0, "", ""))
    monkeypatch.setattr("routes.ups.restart_server", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/ups/myups", json={"desc": "Updated"})
        assert resp.status_code == 200


def test_edit_ups_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.ups.edit_ups", lambda n, d: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/ups/myups", json={"desc": "X"})
        assert resp.status_code == 404


def test_edit_ups_route_invalid_directives():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/ups/myups", json={"directives": "not-a-dict"})
        assert resp.status_code == 400


def test_delete_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.delete_ups", lambda n: True)
    monkeypatch.setattr("routes.ups.restart_server", lambda: (0, "", ""))
    monkeypatch.setattr("routes.ups.restart_monitor", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/ups/myups")
        assert resp.status_code == 200


def test_delete_ups_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.ups.delete_ups", lambda n: False)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/ups/myups")
        assert resp.status_code == 404


def test_scan_ups_route(monkeypatch):
    monkeypatch.setattr("routes.ups.scan_ups", lambda: {"returncode": 0, "devices": []})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups/scan")
        assert resp.status_code == 200


# ── Upsmon routes ─────────────────────────────────────────────────────

def test_get_upsmon_config_route(monkeypatch):
    monkeypatch.setattr("routes.upsmon.get_upsmon_config", lambda: {"monitors": [], "minsupplies": 0})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/upsmon/config")
        assert resp.status_code == 200


def test_put_upsmon_config_route(monkeypatch):
    monkeypatch.setattr("routes.upsmon.put_upsmon_config", lambda d: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/upsmon/config", json={"monitors": [], "minsupplies": 0})
        assert resp.status_code == 200


def test_put_upsmon_config_route_validation_error(monkeypatch):
    monkeypatch.setattr("routes.upsmon.put_upsmon_config", lambda d: (_ for _ in ()).throw(ValueError("bad")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/upsmon/config", json={"monitors": []})
        assert resp.status_code == 400


# ── Users routes ──────────────────────────────────────────────────────

def test_list_users_route(monkeypatch):
    monkeypatch.setattr("routes.users.list_users", lambda: [{"name": "monuser"}])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/users")
        assert resp.status_code == 200


def test_add_user_route(monkeypatch):
    monkeypatch.setattr("routes.users.add_user", lambda d: ({"name": "newuser"}, None))
    monkeypatch.setattr("routes.users.restart_server", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/users", json={"name": "newuser", "password": "secret"})
        assert resp.status_code == 201


def test_add_user_route_no_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/users", json={})
        assert resp.status_code == 400


def test_add_user_route_conflict(monkeypatch):
    monkeypatch.setattr("routes.users.add_user", lambda d: (None, "user already exists"))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/users", json={"name": "dup"})
        assert resp.status_code == 409


def test_edit_user_route(monkeypatch):
    monkeypatch.setattr("routes.users.edit_user", lambda n, d: {"name": "monuser", "upsmon": "slave"})
    monkeypatch.setattr("routes.users.restart_server", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/users/monuser", json={"upsmon": "slave"})
        assert resp.status_code == 200


def test_edit_user_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.users.edit_user", lambda n, d: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/users/monuser", json={"upsmon": "slave"})
        assert resp.status_code == 404


def test_delete_user_route(monkeypatch):
    monkeypatch.setattr("routes.users.delete_user", lambda n: True)
    monkeypatch.setattr("routes.users.restart_server", lambda: (0, "", ""))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/users/monuser")
        assert resp.status_code == 200


def test_delete_user_route_not_found(monkeypatch):
    monkeypatch.setattr("routes.users.delete_user", lambda n: False)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/users/monuser")
        assert resp.status_code == 404


# ── WOL routes ────────────────────────────────────────────────────────

def test_wol_list_targets(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.list_targets", lambda: {"box": {"mac": "aa:bb:cc:dd:ee:ff"}})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/targets")
        assert resp.status_code == 200
        assert "box" in resp.get_json()["targets"]


def test_wol_create_target(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.add_target", lambda **kw: {"mac": "aa:bb:cc:dd:ee:ff"})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets", json={"name": "box", "mac": "aa:bb:cc:dd:ee:ff"})
        assert resp.status_code == 201


def test_wol_create_target_no_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets", json={"mac": "aa:bb:cc:dd:ee:ff"})
        assert resp.status_code == 400


def test_wol_create_target_invalid_mac(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.add_target", lambda **kw: (_ for _ in ()).throw(ValueError("Invalid MAC")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets", json={"name": "box", "mac": "bad"})
        assert resp.status_code == 400


def test_wol_create_target_conflict(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.add_target", lambda **kw: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets", json={"name": "dup", "mac": "aa:bb:cc:dd:ee:ff"})
        assert resp.status_code == 409


def test_wol_update_target(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.update_target", lambda **kw: {"mac": "aa:bb:cc:dd:ee:ff"})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/wol/targets/box", json={"description": "Updated"})
        assert resp.status_code == 200


def test_wol_update_target_not_found(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.update_target", lambda **kw: None)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/wol/targets/box", json={})
        assert resp.status_code == 404


def test_wol_update_target_invalid_mac(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.update_target", lambda **kw: (_ for _ in ()).throw(ValueError("Invalid MAC")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/wol/targets/box", json={"mac": "bad"})
        assert resp.status_code == 400


def test_wol_delete_target(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.delete_target", lambda n: True)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/wol/targets/box")
        assert resp.status_code == 200


def test_wol_delete_target_not_found(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.delete_target", lambda n: False)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/wol/targets/box")
        assert resp.status_code == 404


def test_wol_wake_target(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.send_wol", lambda n: True)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets/box/wake")
        assert resp.status_code == 200


def test_wol_wake_target_not_found(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.send_wol", lambda n: (_ for _ in ()).throw(ValueError("not found")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets/box/wake")
        assert resp.status_code == 404


def test_wol_wake_target_no_package(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.send_wol", lambda n: (_ for _ in ()).throw(RuntimeError("not installed")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets/box/wake")
        assert resp.status_code == 500


def test_wol_wake_all(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.wake_all", lambda: {"box": "ok"})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/wake-all")
        assert resp.status_code == 200


def test_wol_list_mappings(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.list_mappings", lambda: [])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/mappings")
        assert resp.status_code == 200


def test_wol_create_mapping(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.add_mapping", lambda u, e, t: {"ups": "u", "event": "ONLINE", "targets": ["box"]})
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/mappings", json={"ups": "u", "event": "ONLINE", "targets": ["box"]})
        assert resp.status_code == 201


def test_wol_create_mapping_missing_ups():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/mappings", json={"event": "ONLINE", "targets": ["box"]})
        assert resp.status_code == 400


def test_wol_create_mapping_no_targets():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/mappings", json={"ups": "u", "event": "ONLINE", "targets": []})
        assert resp.status_code == 400


def test_wol_create_mapping_validation_error(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.add_mapping", lambda u, e, t: (_ for _ in ()).throw(ValueError("bad")))
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/mappings", json={"ups": "u", "event": "ONLINE", "targets": ["box"]})
        assert resp.status_code == 400


def test_wol_delete_mapping(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.delete_mapping", lambda i: True)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/wol/mappings/0")
        assert resp.status_code == 200


def test_wol_delete_mapping_not_found(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.delete_mapping", lambda i: False)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.delete("/api/wol/mappings/0")
        assert resp.status_code == 404


def test_wol_network_hosts(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.scan_network_hosts", lambda: [
        {"ip": "192.168.1.1", "mac": "AA:BB:CC:DD:EE:FF", "hostname": "router"},
        {"ip": "192.168.1.100", "mac": "11:22:33:44:55:66", "hostname": ""},
    ])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/network-hosts")
        assert resp.status_code == 200
        data = resp.get_json()
        assert len(data["hosts"]) == 2
        assert data["hosts"][0]["mac"] == "AA:BB:CC:DD:EE:FF"
        assert data["hosts"][0]["hostname"] == "router"


def test_wol_network_hosts_empty(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.scan_network_hosts", lambda: [])
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/network-hosts")
        assert resp.status_code == 200
        assert resp.get_json()["hosts"] == []


# ── History routes ─────────────────────────────────────────────────────

def test_history_route(monkeypatch):
    monkeypatch.setattr(
        "routes.history.get_history",
        lambda ups, variables=None, since=0: {
            "ups": ups,
            "variables": {"battery.charge": [[1000000, 100]]},
        },
    )
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/myups?range=24h")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ups"] == "myups"
        assert "battery.charge" in data["variables"]


def test_history_route_invalid_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/%22%22")
        assert resp.status_code == 400


def test_history_route_invalid_range():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/myups?range=bad")
        assert resp.status_code == 400


def test_history_variables_route(monkeypatch):
    monkeypatch.setattr(
        "routes.history.get_available_variables",
        lambda ups: ["battery.charge", "ups.load"],
    )
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/myups/variables")
        assert resp.status_code == 200
        data = resp.get_json()
        assert "battery.charge" in data["variables"]


def test_history_route_with_variables(monkeypatch):
    captured = {}
    def fake_history(ups, variables=None, since=0):
        captured["variables"] = variables
        return {"ups": ups, "variables": {"battery.charge": [[100, 50]]}}
    monkeypatch.setattr("routes.history.get_history", fake_history)
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/myups?range=24h&variables=battery.charge,ups.load")
        assert resp.status_code == 200
        assert captured["variables"] == ["battery.charge", "ups.load"]


def test_history_route_default_range(monkeypatch):
    captured = {}
    def fake_history(ups, variables=None, since=0):
        captured["since"] = since
        return {"ups": ups, "variables": {}}
    monkeypatch.setattr("routes.history.get_history", fake_history)
    app = _register_all(_make_app())
    import time
    before = time.time() - 86400
    with app.test_client() as c:
        resp = c.get("/api/history/myups")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["range"] == "24h"
        assert captured["since"] > before


def test_history_variables_route_invalid_name():
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/%22%22/variables")
        assert resp.status_code == 400


# ── Viewer role: read endpoints allowed, mutating endpoints forbidden ──
# Regression coverage: every pre-existing route used @require_admin for both
# reads and writes, so a "viewer" account (created by the new accounts/API
# keys system) was 403'd on the entire dashboard. Reads should use
# @require_auth (any authenticated principal); only mutations stay
# @require_admin.

def _viewer_headers():
    return {"Authorization": f"Bearer {_create_viewer_bearer()}"}


def test_viewer_can_list_ups(monkeypatch):
    monkeypatch.setattr("routes.ups.list_ups", lambda: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/ups", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_add_ups():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/ups", json={"name": "ups1"}, headers=headers)
        assert resp.status_code == 403


def test_viewer_can_list_users(monkeypatch):
    monkeypatch.setattr("routes.users.list_users", lambda: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/users", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_add_user():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/users", json={"name": "bob"}, headers=headers)
        assert resp.status_code == 403


def test_viewer_can_read_upsmon_config(monkeypatch):
    monkeypatch.setattr("routes.upsmon.get_upsmon_config", lambda: {})
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/upsmon/config", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_write_upsmon_config():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/upsmon/config", json={}, headers=headers)
        assert resp.status_code == 403


def test_viewer_can_list_hooks(monkeypatch):
    monkeypatch.setattr("routes.hooks.list_hooks", lambda n: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/myups", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_write_hook():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/hooks/myups/ONLINE", json={"content": ""}, headers=headers)
        assert resp.status_code == 403


def test_viewer_cannot_read_hook_content(monkeypatch):
    monkeypatch.setattr("routes.hooks.get_hook", lambda n, e: "echo hi")
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/hooks/myups/ONLINE", headers=headers)
        assert resp.status_code == 403


def test_viewer_can_read_config_file(monkeypatch):
    monkeypatch.setattr("routes.system.get_config", lambda f: "content")
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/config/ups.conf", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_write_config_file():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.put("/api/config/ups.conf", data="x", headers=headers)
        assert resp.status_code == 403


def test_viewer_can_read_service_status_detailed(monkeypatch):
    monkeypatch.setattr("routes.system.detailed_service_status", lambda: {})
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/service/status-detailed", headers=headers)
        assert resp.status_code == 200


def test_viewer_can_read_system_resources(monkeypatch):
    monkeypatch.setattr("routes.system.get_system_resources", lambda: {})
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/system/resources", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_trigger_service_action():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/service/restart-server", headers=headers)
        assert resp.status_code == 403


def test_viewer_cannot_reboot_system():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/system/reboot", headers=headers)
        assert resp.status_code == 403


def test_viewer_can_list_wol_targets(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.list_targets", lambda: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/targets", headers=headers)
        assert resp.status_code == 200


def test_viewer_can_list_wol_mappings(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.list_mappings", lambda: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/mappings", headers=headers)
        assert resp.status_code == 200


def test_viewer_cannot_create_wol_target():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets", json={"name": "pc1", "mac": "AA:BB:CC:DD:EE:FF"}, headers=headers)
        assert resp.status_code == 403


def test_viewer_cannot_wake_target():
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.post("/api/wol/targets/pc1/wake", headers=headers)
        assert resp.status_code == 403


def test_viewer_cannot_scan_network_hosts(monkeypatch):
    monkeypatch.setattr("routes.wol.wol_service.scan_network_hosts", lambda: [])
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/wol/network-hosts", headers=headers)
        assert resp.status_code == 403


def test_viewer_can_read_history(monkeypatch):
    monkeypatch.setattr("routes.history.get_history", lambda ups, variables=None, since=0: {"ups": ups, "variables": {}})
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/history/myups", headers=headers)
        assert resp.status_code == 200


def test_viewer_can_read_recent_logs(monkeypatch):
    monkeypatch.setattr("routes.logs.run_cmd", lambda *a, **k: (0, "", ""))
    headers = _viewer_headers()
    app = _register_all(_make_app())
    with app.test_client() as c:
        resp = c.get("/api/logs/recent", headers=headers)
        assert resp.status_code == 200