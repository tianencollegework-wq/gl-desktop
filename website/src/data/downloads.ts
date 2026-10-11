/**
 * 下载页的数据源：**构建期**读 App 的那份 `update.json`。
 *
 * 为什么要读它而不是把地址手抄进页面：手抄必然漂。官方清单
 * （`https://message.gracelink.cc/update.json`）就是 App「检查更新」读的同一份，
 * 下载页用它，官网上的按钮与 App 推的更新永远是同一批产物（plan §7）。
 *
 * 官网上**只渲染**「哪个平台能不能下、点了去哪」，清单里的版本号/内部号
 * 不往页面上放（用户 2026-10-10 的要求：官网不是发版日志）。
 *
 * 三层来源，优先级从高到低：
 *
 * 1. `downloads.override.json` —— 人工覆盖（至少填一格才算数）；
 * 2. 官方清单（构建期 fetch，3 秒超时）；
 * 3. `update.snapshot.json` —— 构建期快照，断网也能出页面。
 *
 * 清单里的 `url` 指向 `example.com` 一律当成**「地址还没接」**，
 * 页面上显示「即将上线」，绝不渲染一个点了 404 的按钮。
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { UPDATE_MANIFEST_URL } from '../consts';

export type PlatformKey = 'windows' | 'android' | 'ios' | 'macos';

export const PLATFORMS: PlatformKey[] = ['windows', 'android', 'ios', 'macos'];

export type ManifestSource = 'override' | 'live' | 'snapshot';

export interface PlatformDownload {
  key: PlatformKey;
  /** 可点的下载地址；null = 还没接入 */
  url: string | null;
  available: boolean;
}

export interface DownloadData {
  platforms: Record<PlatformKey, PlatformDownload>;
  source: ManifestSource;
  /** 构建期的提醒（打给构建日志，不渲染给访客） */
  warnings: string[];
}

const thisDir = fileURLToPath(new URL('.', import.meta.url));

function readJson(path: string): Record<string, unknown> | null {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** 占位符判定：example.com 那种样例域名不算「接好了」 */
function isPlaceholder(url: string): boolean {
  try {
    const { hostname } = new URL(url);
    return /(^|\.)example\.(com|org|net)$/i.test(hostname);
  } catch {
    return true;
  }
}

function urlOf(raw: unknown): string {
  if (!raw || typeof raw !== 'object') return '';
  const value = (raw as Record<string, unknown>).url;
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * 抓清单。**重试 + 宽超时**：首版是 3 秒单次尝试，四个页面各自发一个请求，
 * 于是撞上过一次「首次 TLS 握手 + 并发」导致的超时，整站回落到快照、
 * 四个平台全变成「即将上线」（部署后才发现）。现在超时 8 秒、失败重试 2 次。
 */
async function fetchManifest(attempts = 3, timeoutMs = 8000): Promise<Record<string, unknown> | null> {
  // 需要时强制走快照（离线构建 / CI）：DOWNLOAD_MANIFEST=snapshot
  if (process.env.DOWNLOAD_MANIFEST === 'snapshot') return null;
  for (let i = 1; i <= attempts; i++) {
    try {
      const response = await fetch(UPDATE_MANIFEST_URL, {
        signal: AbortSignal.timeout(timeoutMs),
        headers: { accept: 'application/json' },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = (await response.json()) as unknown;
      if (!data || typeof data !== 'object') throw new Error('清单不是对象');
      return data as Record<string, unknown>;
    } catch (error) {
      if (i === attempts) {
        console.warn(
          `[downloads] 抓 ${UPDATE_MANIFEST_URL} 失败（第 ${i} 次）：` +
            `${(error as Error).message} → 回落到快照`,
        );
        return null;
      }
      await new Promise((resolve) => setTimeout(resolve, 400 * i));
    }
  }
  return null;
}

/**
 * 构建期只读一次清单。
 *
 * 挂在 `globalThis` 上而不是模块变量：Astro 构建里**每个页面是各自的 SSR
 * 模块图**，模块级缓存不共享，四个页面会各发一次请求（首版就是这样并发四次，
 * 把其中一次撞成了超时）。
 */
const CACHE_KEY = '__gracelinkDownloads';
function cache(): { promise?: Promise<DownloadData> } {
  const holder = globalThis as Record<string, unknown>;
  return (holder[CACHE_KEY] ??= {}) as { promise?: Promise<DownloadData> };
}

function warnOnce(lines: string[]): void {
  const seen = ((globalThis as Record<string, unknown>).__gracelinkDownloadWarnings ??=
    new Set<string>()) as Set<string>;
  for (const line of lines) {
    if (seen.has(line)) continue;
    seen.add(line);
    console.warn(line);
  }
}

async function loadDownloads(): Promise<DownloadData> {
  const warnings: string[] = [];

  const overrideRaw = readJson(`${thisDir}downloads.override.json`);
  const override =
    overrideRaw && PLATFORMS.some((key) => urlOf(overrideRaw[key])) ? overrideRaw : null;
  const live = override ? null : await fetchManifest();
  const snapshot = override || live ? null : readJson(`${thisDir}update.snapshot.json`);

  const source: ManifestSource = override ? 'override' : live ? 'live' : 'snapshot';
  const manifest = override ?? live ?? snapshot ?? {};

  if (source === 'snapshot') {
    warnings.push(
      `[downloads] 读不到官方清单（${UPDATE_MANIFEST_URL}），已回落到构建期快照 ` +
        `src/data/update.snapshot.json。想离线构建可以显式设 DOWNLOAD_MANIFEST=snapshot。`,
    );
  }

  const platforms = {} as Record<PlatformKey, PlatformDownload>;
  for (const key of PLATFORMS) {
    const url = urlOf(manifest[key]);
    if (!url) {
      platforms[key] = { key, url: null, available: false };
      continue;
    }
    const placeholder = isPlaceholder(url);
    if (placeholder) {
      warnings.push(
        `[downloads] ${key} 这一格的 url 还是占位符（${url}）→ 页面上会显示「即将上线」。` +
          `发版时要么改服务端 update.json，要么填 src/data/downloads.override.json。`,
      );
    }
    platforms[key] = { key, url: placeholder ? null : url, available: !placeholder };
  }

  warnOnce(warnings);
  return { platforms, source, warnings };
}

export function getDownloads(): Promise<DownloadData> {
  const holder = cache();
  holder.promise ??= loadDownloads();
  return holder.promise;
}
