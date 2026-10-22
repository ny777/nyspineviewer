/**
 * 偏好持久化管理（对齐 Android 版 SharedPreferences 键名）。
 * Android 源参考：SpineModelLoader.SlotPrefs / SpineWallpaperService.kt。
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/** 偏好键名常量（与 Android 版 spine_wallpaper_prefs 完全对齐）。 */
export class PrefsKeys {
  static readonly ACTIVE_MODEL_ID: string = 'active_model_id';
  static readonly MODEL2_ID: string = 'model2_id';
  static readonly ACTIVE_ANIMATION_NAME: string = 'active_animation_name';
  static readonly MODEL2_ANIMATION: string = 'model2_animation';
  static readonly ACTIVE_SKINS_JSON: string = 'active_skins_json';
  static readonly ACTIVE_SKINS_JSON_2: string = 'active_skins_json_2';
  static readonly MODEL_SCALE: string = 'model_scale';
  static readonly MODEL_POS_X: string = 'model_pos_x';
  static readonly MODEL_POS_Y: string = 'model_pos_y';
  static readonly MODEL2_SCALE: string = 'model2_scale';
  static readonly MODEL2_POS_X: string = 'model2_pos_x';
  static readonly MODEL2_POS_Y: string = 'model2_pos_y';
  static readonly SELECTED_SLOT: string = 'selected_slot';
  static readonly PMA_ENABLED: string = 'pma_enabled';
  static readonly PMA2_ENABLED: string = 'pma2_enabled';
  static readonly MODEL_MIRRORED: string = 'model_mirrored';
  static readonly MODEL2_MIRRORED: string = 'model2_mirrored';
  static readonly MODEL_ALPHA: string = 'model_alpha';
  static readonly MODEL2_ALPHA: string = 'model2_alpha';
  static readonly BG_COLOR: string = 'bg_color';
  static readonly BG_IMAGE_PATH: string = 'bg_image_path';

  static readonly LAST_IMPORT_GROUP: string = 'last_import_group';
  static readonly THEME_MODE: string = 'theme_mode';
  static readonly BG_FAVORITES: string = 'bg_favorites';
  static readonly TARGET_FPS: string = 'target_fps';
  static readonly TAP_SWITCH_ANIMATION: string = 'tap_switch_animation';
  static readonly WIDGET_AUTO_UPDATE: string = 'widget_auto_update';
  static readonly KEEP_SCREEN_ON: string = 'keep_screen_on';
  static readonly ANIMATION_ROTATION_ENABLED: string = 'animation_rotation_enabled';
  static readonly ANIMATION_ROTATION_INTERVAL: string = 'animation_rotation_interval';
  static readonly LIBRARY_SORT: string = 'library_sort';
  static readonly TRASH_RETENTION_DAYS: string = 'trash_retention_days';
  static readonly MODEL_SPEED: string = 'model_speed';
  static readonly MODEL2_SPEED: string = 'model2_speed';
  static readonly ACTIVE_PLAYLIST_JSON: string = 'active_playlist_json';
  static readonly MODEL2_PLAYLIST_JSON: string = 'model2_playlist_json';
  static readonly ANIMATION_MIX: string = 'animation_mix_seconds';
}

const PREFS_STORE_NAME = 'spine_wallpaper_prefs';
const DEFAULT_BG_COLOR = 0xFF0F172A;

/** 按槽位派生偏好键（0 主 / 1 副）。 */
export class SlotPrefs {
  static scaleKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_SCALE : PrefsKeys.MODEL_SCALE;
  }

  static posXKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_POS_X : PrefsKeys.MODEL_POS_X;
  }

  static posYKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_POS_Y : PrefsKeys.MODEL_POS_Y;
  }

  static animationKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_ANIMATION : PrefsKeys.ACTIVE_ANIMATION_NAME;
  }

  static skinsJsonKey(slot: number): string {
    return slot === 1 ? PrefsKeys.ACTIVE_SKINS_JSON_2 : PrefsKeys.ACTIVE_SKINS_JSON;
  }

  static pmaKey(slot: number): string {
    return slot === 1 ? PrefsKeys.PMA2_ENABLED : PrefsKeys.PMA_ENABLED;
  }

  static mirrorKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_MIRRORED : PrefsKeys.MODEL_MIRRORED;
  }

  static alphaKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_ALPHA : PrefsKeys.MODEL_ALPHA;
  }

  static speedKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_SPEED : PrefsKeys.MODEL_SPEED;
  }

  static playlistJsonKey(slot: number): string {
    return slot === 1 ? PrefsKeys.MODEL2_PLAYLIST_JSON : PrefsKeys.ACTIVE_PLAYLIST_JSON;
  }
}

/** 轮播列表持久化结构（槽位级）。 */
export class PlaylistPrefs {
  enabled: boolean;
  names: Array<string>;

  constructor(enabled: boolean, names: Array<string>) {
    this.enabled = enabled;
    this.names = names;
  }
}

/** PlaylistPrefs JSON 原始结构（仅用于 JSON.parse 单次断言归一）。 */
interface PlaylistPrefsRaw {
  enabled?: Object;
  names?: Array<Object>;
}

/**
 * preferences 单例封装。所有读写均为同步方法（getSync/putSync），
 * put 后由调用方决定 flush 时机（关键路径手动 flush）。
 */
export class PrefsManager {
  private static instance: PrefsManager | null = null;
  private store: preferences.Preferences | null = null;

  private constructor(store: preferences.Preferences) {
    this.store = store;
  }

  static async getInstance(context: Context): Promise<PrefsManager> {
    if (PrefsManager.instance === null) {
      const store = await preferences.getPreferences(context, PREFS_STORE_NAME);
      PrefsManager.instance = new PrefsManager(store);
    }
    return PrefsManager.instance;
  }

  getString(key: string, defValue: string): string {
    const value = this.store?.getSync(key, defValue);
    if (typeof value === 'string') {
      return value;
    }
    return defValue;
  }

  getNumber(key: string, defValue: number): number {
    const value = this.store?.getSync(key, defValue);
    if (typeof value === 'number') {
      return value;
    }
    return defValue;
  }

  getBool(key: string, defValue: boolean): boolean {
    const value = this.store?.getSync(key, defValue);
    if (typeof value === 'boolean') {
      return value;
    }
    return defValue;
  }

  /** 读取多选皮肤 JSON（JSONArray 字符串）为集合；兼容旧单选字段回退。 */
  getSelectedSkins(skinsJsonKey: string, fallbackSingleKey: string): Array<string> {
    const result: Array<string> = [];
    const json = this.getString(skinsJsonKey, '');
    if (json.length > 0) {
      try {
        const parsed = JSON.parse(json) as Array<Object>;
        if (Array.isArray(parsed)) {
          for (const item of parsed) {
            if (typeof item === 'string' && item.trim().length > 0) {
              result.push(item);
            }
          }
        }
      } catch (err) {
        console.error(`PrefsManager parse skins json failed: ${JSON.stringify(err)}`);
      }
    }
    if (result.length === 0) {
      const fallback = this.getString(fallbackSingleKey, '');
      if (fallback.length > 0) {
        result.push(fallback);
      }
    }
    return result;
  }

  putString(key: string, value: string): void {
    this.store?.putSync(key, value);
  }

  putNumber(key: string, value: number): void {
    this.store?.putSync(key, value);
  }

  putBool(key: string, value: boolean): void {
    this.store?.putSync(key, value);
  }

  /** 写入多选皮肤集合（序列化为 JSONArray 字符串）。 */
  putSelectedSkins(skinsJsonKey: string, skins: Array<string>): void {
    this.store?.putSync(skinsJsonKey, JSON.stringify(skins));
  }

  /** 读取轮播列表偏好；损坏/缺失回退为关闭 + 空列表。 */
  getPlaylist(key: string): PlaylistPrefs {
    const json = this.getString(key, '');
    if (json.length > 0) {
      try {
        const parsed = JSON.parse(json) as PlaylistPrefsRaw;
        if (parsed !== null && typeof parsed.enabled === 'boolean') {
          const names = new Array<string>();
          const rawNames = parsed.names;
          if (rawNames !== undefined && rawNames !== null) {
            for (const item of rawNames) {
              if (typeof item === 'string' && item.length > 0) {
                names.push(item);
              }
            }
          }
          return new PlaylistPrefs(parsed.enabled, names);
        }
      } catch (err) {
        console.error(`PrefsManager parse playlist json failed: ${JSON.stringify(err)}`);
      }
    }
    return new PlaylistPrefs(false, new Array<string>());
  }

  /** 写入轮播列表偏好（序列化为 JSON 字符串）。 */
  putPlaylist(key: string, playlist: PlaylistPrefs): void {
    this.store?.putSync(key, JSON.stringify(playlist));
  }

  /** 同步落盘（阻塞直至写入完成）。 */
  flushSync(): void {
    this.store?.flushSync();
  }

  /** 异步落盘。 */
  async flush(): Promise<void> {
    await this.store?.flush();
  }

  /** 默认背景色（对齐 Android 版 0xFF0F172A）。 */
  static get defaultBgColor(): number {
    return DEFAULT_BG_COLOR;
  }
}
