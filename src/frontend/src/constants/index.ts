export const SECTIONS = {
  DASHBOARD: 'dashboard',
  UPS: 'ups',
  UPS_DETAIL: 'ups-detail',
  USERS: 'users',
  NOTIFICATIONS: 'notifications',
  LOGS: 'logs',
  CONFIG: 'config',
  HOOKS: 'hooks',
  WOL: 'wol',
} as const;

export const SECTION_TITLES: Record<string, string> = {
  [SECTIONS.DASHBOARD]: 'Dashboard',
  [SECTIONS.UPS]: 'UPS Devices',
  [SECTIONS.UPS_DETAIL]: 'UPS Detail',
  [SECTIONS.USERS]: 'Users',
  [SECTIONS.NOTIFICATIONS]: 'Notifications',
  [SECTIONS.LOGS]: 'Logs',
  [SECTIONS.CONFIG]: 'Config Files',
  [SECTIONS.HOOKS]: 'Hooks',
  [SECTIONS.WOL]: 'Wake on LAN',
};

export const API = {
  UPS: '/ups',
  UPS_SCAN: '/ups/scan',
  USERS: '/users',
  UPSMON_CONFIG: '/upsmon/config',
  SERVICE_STATUS: '/service/status-detailed',
  SERVICE_RESTART_MONITOR: '/service/restart-monitor',
  SERVICE_RESTART_ALL: '/service/restart-all',
  SYSTEM_RESOURCES: '/system/resources',
  SYSTEM_REBOOT: '/system/reboot',
  SYSTEM_SHUTDOWN: '/system/shutdown',
  SYSTEM_RESTART_NUTWATCH: '/system/restart-nutwatch',
  LOGS_STREAM: '/api/logs/stream',
  LOGS_RECENT: '/logs/recent?lines=100',
  hooks: (upsname: string, event?: string) =>
    event
      ? `/hooks/${encodeURIComponent(upsname)}/${encodeURIComponent(event)}`
      : `/hooks/${encodeURIComponent(upsname)}`,
  ups: (name: string) => `/ups/${encodeURIComponent(name)}`,
  upsDetail: (name: string) => `/ups/${encodeURIComponent(name)}/detail`,
  user: (name: string) => `/users/${encodeURIComponent(name)}`,
  configFile: (filename: string) => `/config/${encodeURIComponent(filename)}`,
  driver: (name: string, action: string) => `/driver/${encodeURIComponent(name)}/${action}`,
  wolTarget: (name: string) => `/wol/targets/${encodeURIComponent(name)}`,
  wolWake: (name: string) => `/wol/targets/${encodeURIComponent(name)}/wake`,
  wolMapping: (id: number) => `/wol/mappings/${encodeURIComponent(id)}`,
  WOL_TARGETS: '/wol/targets',
  WOL_MAPPINGS: '/wol/mappings',
  WOL_WAKE_ALL: '/wol/wake-all',
  WOL_NETWORK_HOSTS: '/wol/network-hosts',
  history: (ups: string, range: string, vars?: string[]) => {
    let p = `/history/${encodeURIComponent(ups)}?range=${encodeURIComponent(range)}`;
    if (vars) p += `&variables=${vars.map(v => encodeURIComponent(v)).join(',')}`;
    return p;
  },
  historyVariables: (ups: string) => `/history/${encodeURIComponent(ups)}/variables`,
  AUTH_STATUS: '/auth/status',
  AUTH_SETUP: '/auth/setup',
  AUTH_LOGIN: '/auth/login',
  AUTH_LOGOUT: '/auth/logout',
  AUTH_ME: '/auth/me',
  ACCOUNTS: '/accounts',
  account: (id: number) => `/accounts/${id}`,
  API_KEYS: '/apikeys',
  apiKey: (id: number) => `/apikeys/${id}`,
};

export const DEFAULTS = {
  DRIVER: 'usbhid-ups',
  PORT: 'auto',
  POLL_INTERVAL: '5',
};

export const ROLES = {
  MASTER: 'master',
  SLAVE: 'slave',
} as const;

export const FLAGS = ['SYSLOG', 'WALL', 'EXEC', 'IGNORE'] as const;

export const NOTIFICATION_EVENTS = [
  'ONLINE', 'ONBATT', 'LOWBATT', 'COMMOK', 'COMMBAD',
  'SHUTDOWN', 'REPLBATT', 'NOCOMM', 'NOPARENT',
] as const;

export const TIMING_KEYS = [
  'POLLFREQ', 'POLLFREQALERT', 'HOSTSYNC', 'DEADTIME',
  'RBWARNTIME', 'NOCOMMWARNTIME', 'FINALDELAY',
] as const;

export const BADGE_CLASSES = {
  ONLINE: 'online',
  ONBATT: 'onbatt',
  OFFLINE: 'offline',
  UNKNOWN: 'unknown',
} as const;

export const BADGE_KNOWN_CLASSES = [BADGE_CLASSES.ONLINE, BADGE_CLASSES.ONBATT, BADGE_CLASSES.OFFLINE] as const;

export const CONFIG_FILENAMES = ['ups.conf', 'upsd.conf', 'upsmon.conf', 'upsd.users'] as const;

export const READONLY_CONFIG = 'upsd.users';

export const APP_VERSION = 'v1.1.2';

export const MAX_LOG_LINES = 1000;

export const POLL_INTERVAL_MIN = 5;
