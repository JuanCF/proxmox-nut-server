export interface UpsDevice {
  name: string;
  driver: string;
  port: string;
  desc?: string;
  status?: string;
  directives?: [string, string][];
}

export type UpsDetailData = Record<string, number | string>;

export interface ServiceInfo {
  active: boolean;
  state: string;
}

export type ServicesMap = Record<string, ServiceInfo>;

export interface NutUser {
  name: string;
  password: string;
  upsmon?: string;
  actions?: string;
  instcmds?: string;
}

export interface WolTarget {
  mac: string;
  broadcast?: string;
  description?: string;
}

export type WolTargetsMap = Record<string, WolTarget>;

export interface WolTargetWithName extends WolTarget {
  name: string;
}

export interface WolMapping {
  ups: string;
  event: string;
  targets: string[];
}

export interface ScanDevice {
  scanner_name: string;
  driver?: string;
  port?: string;
  desc?: string;
  vendorid?: string;
  productid?: string;
  extra?: Record<string, string>;
}

export interface ApiMonitor {
  upsname: string;
  hostspec: string;
  power: number;
  username: string;
  password: string;
  role: string;
}

export interface MonitorRow {
  __id: number;
  upsname: string;
  hostspec: string;
  power: string;
  username: string;
  password: string;
  role: string;
}

export interface UpsmonConfig {
  monitors?: ApiMonitor[];
  minsupplies?: number;
  shutdowncmd?: string | null;
  notifycmd?: string | null;
  powerdownflag?: string | null;
  timing?: Record<string, number>;
  notify_msg?: Record<string, string>;
  notify_flag?: Record<string, string[]>;
}

export interface SystemResources {
  cpu_percent: number | null;
  memory_percent: number | null;
  memory_used_gb: number | null;
  memory_total_gb: number | null;
  disk_percent: number | null;
  disk_free_gb: number | null;
  disk_total_gb: number | null;
}

export interface CommandResult {
  returncode: number;
  stdout?: string;
  stderr?: string;
}

export type ThemeMode = 'system' | 'light' | 'dark' | 'auto';

export type AccountRole = 'admin' | 'viewer';

export interface Account {
  id: number;
  username: string;
  role: AccountRole;
  is_active: boolean;
  created_at: number;
  last_login_at: number | null;
}

export interface ApiKey {
  id: number;
  account_id: number;
  label: string | null;
  key_prefix: string;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
}

export interface ApiKeyCreated extends ApiKey {
  key: string;
}
