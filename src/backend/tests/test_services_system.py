import os

import pytest


def _fake_rc(rc, out="", err=""):
    return (rc, out, err)


def test_restart_server(monkeypatch):
    calls = []
    monkeypatch.setattr("services.system.run_cmd", lambda cmd, **kw: (calls.append(cmd), _fake_rc(0))[1])
    from services.system import restart_server
    rc, _, _ = restart_server()
    assert rc == 0
    assert any("nut-server" in c for c in calls)


def test_restart_monitor(monkeypatch):
    calls = []
    monkeypatch.setattr("services.system.run_cmd", lambda cmd, **kw: (calls.append(cmd), _fake_rc(0))[1])
    from services.system import restart_monitor
    rc, _, _ = restart_monitor()
    assert rc == 0


def test_restart_driver_bare_unit(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "list-unit-files" in cmd:
            return _fake_rc(0, "nut-driver.service enabled")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import restart_driver
    rc, _, _ = restart_driver()
    assert rc == 0
    assert calls[-1] == ["systemctl", "restart", "nut-driver"]


def test_restart_driver_template_units(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "list-unit-files" in cmd:
            return _fake_rc(1, "0 unit files listed.")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: ["ups1", "ups2"])
    from services.system import restart_driver
    rc, _, _ = restart_driver()
    assert rc == 0
    assert ["systemctl", "restart", "nut-driver@ups1"] in calls
    assert ["systemctl", "restart", "nut-driver@ups2"] in calls


def test_restart_driver_upsdrvctl_fallback(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "list-unit-files" in cmd:
            return _fake_rc(1, "0 unit files listed.")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: [])
    from services.system import restart_driver
    rc, _, _ = restart_driver()
    assert rc == 0
    assert ["upsdrvctl", "stop"] in calls
    assert ["upsdrvctl", "start"] in calls


def test_restart_driver_ignores_template_unit_row(monkeypatch):
    # list-unit-files may exit 0 while listing only the nut-driver@.service
    # template; only a row whose first field is exactly nut-driver.service
    # selects the bare unit.
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "list-unit-files" in cmd:
            return _fake_rc(0, "nut-driver@.service  enabled         enabled")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: ["ups1"])
    from services.system import restart_driver
    rc, _, _ = restart_driver()
    assert rc == 0
    assert ["systemctl", "restart", "nut-driver@ups1"] in calls


def test_restart_driver_upsdrvctl_stop_failure_propagates(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "list-unit-files" in cmd:
            return _fake_rc(1, "0 unit files listed.")
        if cmd == ["upsdrvctl", "stop"]:
            return _fake_rc(1, "", "stop failed")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: [])
    from services.system import restart_driver
    rc, _, err = restart_driver()
    assert rc == 1
    assert "stop failed" in err
    assert ["upsdrvctl", "start"] in calls


def test_restart_all(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import restart_all
    rc, _, _ = restart_all()
    assert rc == 0
    assert len(calls) == 2


def test_restart_all_fails(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append(cmd)
        rc = 1 if "nut-server" in cmd else 0
        return _fake_rc(rc)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import restart_all
    rc, _, _ = restart_all()
    assert rc == 1


def test_detailed_service_status(monkeypatch):
    def fake_run(cmd, **kw):
        if "list-unit-files" in cmd:
            return _fake_rc(0, "nut-driver.service enabled")
        if cmd[:2] == ["systemctl", "is-active"]:
            if "nut-driver" in cmd[2:]:
                return _fake_rc(0, "active")
            if "nut-server" in cmd[2:]:
                return _fake_rc(3, "inactive")
            return _fake_rc(0, "active")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import detailed_service_status
    result = detailed_service_status()
    assert result["nut-driver"]["active"] is True
    assert result["nut-server"]["active"] is False
    assert result["nut-monitor"]["active"] is True


def test_detailed_service_status_template_instances(monkeypatch):
    def fake_run(cmd, **kw):
        if "list-unit-files" in cmd:
            return _fake_rc(1, "0 unit files listed.")
        if cmd[:2] == ["systemctl", "is-active"]:
            if "nut-driver" in cmd[2:]:
                assert cmd[2:] == ["nut-driver@ups"]
            return _fake_rc(0, "active")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: ["ups"])
    from services.system import detailed_service_status
    result = detailed_service_status()
    assert result["nut-driver"]["active"] is True


def test_detailed_service_status_pidfile_fallback(monkeypatch, tmp_path):
    def fake_run(cmd, **kw):
        if "list-unit-files" in cmd:
            return _fake_rc(1, "0 unit files listed.")
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system._ups_names", lambda: [])
    monkeypatch.setattr("services.system.glob.glob", lambda p: [str(tmp_path / "ups.pid")])
    (tmp_path / "ups.pid").write_text(str(os.getpid()))
    from services.system import detailed_service_status
    result = detailed_service_status()
    assert result["nut-driver"]["active"] is True
    assert result["nut-driver"]["state"] == "active"


def test_service_status(monkeypatch):
    monkeypatch.setattr("services.system.run_cmd", lambda cmd, **kw: _fake_rc(0, "active"))
    from services.system import service_status
    rc, out, _ = service_status()
    assert rc == 0
    assert "active" in out


def test_driver_action_invalid_name():
    from services.system import driver_action
    rc, _, err = driver_action("bad name!", "start")
    assert rc == 1
    assert "Invalid UPS name" in err


def test_driver_action_stop(monkeypatch):
    monkeypatch.setattr("services.system.stop_driver_and_cleanup", lambda n: (0, "", ""))
    from services.system import driver_action
    rc, _, _ = driver_action("myups", "stop")
    assert rc == 0


def test_driver_action_start(monkeypatch):
    monkeypatch.setattr("services.system.run_cmd", lambda cmd, **kw: _fake_rc(0))
    monkeypatch.setattr("services.system._remove_stale_pid_files", lambda n: None)
    from services.system import driver_action
    rc, _, _ = driver_action("myups", "start")
    assert rc == 0


def test_driver_action_restart(monkeypatch):
    monkeypatch.setattr("services.system.stop_driver_and_cleanup", lambda n: (0, "", ""))
    monkeypatch.setattr("services.system.run_cmd", lambda cmd, **kw: _fake_rc(0))
    from services.system import driver_action
    rc, _, _ = driver_action("myups", "restart")
    assert rc == 0


def test_get_config_allowed(monkeypatch):
    monkeypatch.setattr("services.system.read_file", lambda p: "content")
    monkeypatch.setattr("services.system.NUT_DIR", "/etc/nut")
    from services.system import get_config
    assert get_config("ups.conf") == "content"


def test_get_config_not_allowed():
    from services.system import get_config
    assert get_config("../../etc/passwd") is None


def test_get_config_not_found(monkeypatch):
    monkeypatch.setattr("services.system.read_file", lambda p: (_ for _ in ()).throw(FileNotFoundError))
    monkeypatch.setattr("services.system.NUT_DIR", "/etc/nut")
    from services.system import get_config
    assert get_config("ups.conf") is None


def test_put_config_allowed(monkeypatch):
    writes = {}
    monkeypatch.setattr("services.system.write_file", lambda p, c: writes.update({p: c}))
    monkeypatch.setattr("services.system.NUT_DIR", "/etc/nut")
    from services.system import put_config
    assert put_config("upsmon.conf", "data") is True
    assert list(writes.values()) == ["data"]


def test_put_config_not_allowed():
    from services.system import put_config
    assert put_config("evil.conf", "data") is False


def test_put_config_upsd_users_forbidden():
    from services.system import put_config
    assert put_config("upsd.users", "data") is False


def test_put_config_write_fail(monkeypatch):
    monkeypatch.setattr("services.system.write_file", lambda p, c: (_ for _ in ()).throw(OSError))
    monkeypatch.setattr("services.system.NUT_DIR", "/etc/nut")
    from services.system import put_config
    assert put_config("upsmon.conf", "data") is False


def test_remove_stale_pid_files(tmp_path, monkeypatch):
    monkeypatch.setattr("services.system.glob.glob", lambda p: [str(tmp_path / "nut-myups.pid")])
    pidf = tmp_path / "nut-myups.pid"
    pidf.write_text("99999")
    from services.system import _remove_stale_pid_files
    _remove_stale_pid_files("myups")
    assert not pidf.exists()


def test_reboot_system(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append((cmd, kw))
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import reboot_system
    rc, _, _ = reboot_system()
    assert rc == 0
    assert any("reboot" in c for c, kw in calls)
    assert any(kw.get("timeout") == 10 for _, kw in calls)


def test_shutdown_system(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append((cmd, kw))
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    from services.system import shutdown_system
    rc, _, _ = shutdown_system()
    assert rc == 0
    assert any("poweroff" in c for c, kw in calls)
    assert any(kw.get("timeout") == 10 for _, kw in calls)


def test_restart_nutwatch(monkeypatch):
    calls = []
    def fake_run(cmd, **kw):
        calls.append((cmd, kw))
        return _fake_rc(0)
    monkeypatch.setattr("services.system.run_cmd", fake_run)
    monkeypatch.setattr("services.system.time.sleep", lambda s: None)

    class FakeThread:
        def __init__(self, target, daemon=False):
            self._target = target

        def start(self):
            self._target()

    monkeypatch.setattr("services.system.threading.Thread", FakeThread)
    from services.system import restart_nutwatch
    rc, out, _ = restart_nutwatch()
    assert rc == 0
    assert out == "restart scheduled"
    assert any("nutwatch" in c for c, kw in calls)
    assert any(kw.get("timeout") == 10 for _, kw in calls)
