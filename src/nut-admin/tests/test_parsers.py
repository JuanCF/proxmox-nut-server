from app import parse_ups_conf, serialize_ups_conf, parse_upsd_users, serialize_upsd_users


def test_parse_ups_conf_basic():
    content = "[myups]\n  driver = usbhid-ups\n  port = auto\n"
    entries = parse_ups_conf(content)
    assert len(entries) == 1
    assert entries[0]["name"] == "myups"
    assert entries[0]["driver"] == "usbhid-ups"
    assert entries[0]["port"] == "auto"


def test_parse_ups_conf_with_comments():
    content = "# this is a comment\n\n[myups]\n  driver = usbhid-ups\n"
    entries = parse_ups_conf(content)
    assert len(entries) == 1
    assert entries[0]["name"] == "myups"


def test_ups_conf_roundtrip():
    content = '[myups]\n  driver = usbhid-ups\n  port = auto\n  desc = "My UPS"\n'
    entries = parse_ups_conf(content)
    serialized = serialize_ups_conf(entries)
    entries2 = parse_ups_conf(serialized)
    assert entries == entries2


def test_parse_upsd_users_basic():
    content = "[monuser]\n  password = secret\n  upsmon = slave\n"
    entries = parse_upsd_users(content)
    assert len(entries) == 1
    assert entries[0]["name"] == "monuser"
    assert entries[0]["password"] == "secret"
    assert entries[0]["upsmon"] == "slave"


def test_upsd_users_roundtrip():
    content = "[monuser]\n  password = secret\n  upsmon = slave\n"
    entries = parse_upsd_users(content)
    serialized = serialize_upsd_users(entries)
    entries2 = parse_upsd_users(serialized)
    assert entries == entries2


def test_upsd_users_with_actions():
    content = "[admin]\n  password = secret\n  actions = SET\n  instcmds = all\n"
    entries = parse_upsd_users(content)
    assert len(entries) == 1
    assert entries[0]["actions"] == "SET"
    assert entries[0]["instcmds"] == "all"


def test_parse_ups_conf_multiple():
    content = "[ups1]\n  driver = usbhid-ups\n\n[ups2]\n  driver = blazer_usb\n"
    entries = parse_ups_conf(content)
    assert len(entries) == 2
    assert entries[0]["name"] == "ups1"
    assert entries[1]["name"] == "ups2"


def test_ups_conf_extra_directives():
    content = "[myups]\n  driver = usbhid-ups\n  port = auto\n  vendorid = 0463\n"
    entries = parse_ups_conf(content)
    assert len(entries) == 1
    assert entries[0]["directives"] == [["vendorid", "0463"]]
