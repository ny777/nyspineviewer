/**
 * 桌面卡片存储与更新（卡片进程与主进程共用）：
 * - WidgetFormsStore：已添加卡片 formId 登记表（filesDir/widget_forms.json，JSON 文件而非
 *   preferences，避免跨进程缓存失效）。
 * - WidgetSnapshotStore：当前模型快照（filesDir/widget_snapshot.png + widget_meta.json）。
 * - WidgetUpdater：组装 formImages fd 数据并经 formProvider 推送刷新。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';

const TAG = 'WidgetStore';

/** widget_meta.json 原始结构（JSON.parse 单次断言归一用）。 */
interface WidgetMetaRaw {
  title?: Object;
}

/** 已添加卡片 formId 登记（JSON 文件持久化）。 */
export class WidgetFormsStore {
  static formsPath(context: Context): string {
    return `${context.filesDir}/widget_forms.json`;
  }

  static readFormIds(context: Context): Array<string> {
    const result = new Array<string>();
    try {
      const text = fileIo.readTextSync(WidgetFormsStore.formsPath(context));
      const raw = JSON.parse(text) as Array<Object>;
      if (!Array.isArray(raw)) {
        return result;
      }
      for (const item of raw) {
        if (typeof item === 'string' && item.length > 0) {
          result.push(item);
        }
      }
    } catch (err) {
      // 文件不存在或损坏：视为空表
    }
    return result;
  }

  static addForm(context: Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    const ids = WidgetFormsStore.readFormIds(context);
    if (ids.indexOf(formId) < 0) {
      ids.push(formId);
      WidgetFormsStore.writeFormIds(context, ids);
    }
  }

  static removeForm(context: Context, formId: string): void {
    const ids = WidgetFormsStore.readFormIds(context);
    const idx = ids.indexOf(formId);
    if (idx >= 0) {
      ids.splice(idx, 1);
      WidgetFormsStore.writeFormIds(context, ids);
    }
  }

  private static writeFormIds(context: Context, ids: Array<string>): void {
    const file = fileIo.openSync(WidgetFormsStore.formsPath(context),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, JSON.stringify(ids));
    } finally {
      fileIo.closeSync(file);
    }
  }
}

/** 快照文件落盘与读取。 */
export class WidgetSnapshotStore {
  static snapshotPath(context: Context): string {
    return `${context.filesDir}/widget_snapshot.png`;
  }

  static metaPath(context: Context): string {
    return `${context.filesDir}/widget_meta.json`;
  }

  static hasSnapshot(context: Context): boolean {
    try {
      return fileIo.accessSync(WidgetSnapshotStore.snapshotPath(context));
    } catch (err) {
      return false;
    }
  }

  static saveSnapshot(context: Context, base64Png: string, title: string): void {
    const bytes = new util.Base64Helper().decodeSync(base64Png);
    const pngFile = fileIo.openSync(WidgetSnapshotStore.snapshotPath(context),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(pngFile.fd, bytes.buffer);
    } finally {
      fileIo.closeSync(pngFile);
    }
    const metaFile = fileIo.openSync(WidgetSnapshotStore.metaPath(context),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      const meta: Record<string, Object> = { 'title': title };
      fileIo.writeSync(metaFile.fd, JSON.stringify(meta));
    } finally {
      fileIo.closeSync(metaFile);
    }
  }

  static readTitle(context: Context): string {
    try {
      const text = fileIo.readTextSync(WidgetSnapshotStore.metaPath(context));
      const raw = JSON.parse(text) as WidgetMetaRaw;
      if (raw.title !== undefined && typeof raw.title === 'string') {
        return raw.title;
      }
    } catch (err) {
      // 元数据缺失：返回空标题
    }
    return '';
  }
}

/** 快照卡片数据载体：formData + 需关闭的文件 fd（无图时 fd 为 -1）。 */
export class WidgetSnapshotData {
  formData: formBindingData.FormBindingData;
  fd: number;

  constructor(formData: formBindingData.FormBindingData, fd: number) {
    this.formData = formData;
    this.fd = fd;
  }
}

/** 组装快照数据并推送刷新。 */
export class WidgetUpdater {
  /** 组装卡片数据：有快照 → formImages fd 引用（fd 保持打开，由调用方在更新落定后关闭）；
   * 无快照 → 空数据（卡片显示占位 UI）。 */
  static buildSnapshotData(context: Context): WidgetSnapshotData {
    if (WidgetSnapshotStore.hasSnapshot(context)) {
      const title = WidgetSnapshotStore.readTitle(context);
      const file = fileIo.openSync(WidgetSnapshotStore.snapshotPath(context), fileIo.OpenMode.READ_ONLY);
      const formImages: Record<string, number> = { 'snapshot': file.fd };
      const data: Record<string, Object> = {
        'title': title,
        'imgSrc': 'memory://snapshot',
        'formImages': formImages
      };
      return new WidgetSnapshotData(formBindingData.createFormBindingData(data), file.fd);
    }
    const empty: Record<string, Object> = { 'title': '', 'imgSrc': '' };
    return new WidgetSnapshotData(formBindingData.createFormBindingData(empty), -1);
  }

  /** 刷新全部已登记卡片；返回成功数。单个失败仅记录日志并继续。 */
  static async updateAll(context: Context): Promise<number> {
    const formIds = WidgetFormsStore.readFormIds(context);
    let successCount = 0;
    for (const formId of formIds) {
      const data = WidgetUpdater.buildSnapshotData(context);
      try {
        await formProvider.updateForm(formId, data.formData);
        successCount++;
      } catch (err) {
        console.error(`${TAG} updateForm ${formId} failed: ${JSON.stringify(err)}`);
      } finally {
        if (data.fd >= 0) {
          try {
            fileIo.closeSync(data.fd);
          } catch (err) {
            // fd 已失效可忽略
          }
        }
      }
    }
    return successCount;
  }

  /** 刷新单张卡片（EntryFormAbility 刷新消息用）；失败向上抛出由调用方记录。 */
  static async updateFormById(context: Context, formId: string): Promise<void> {
    const data = WidgetUpdater.buildSnapshotData(context);
    try {
      await formProvider.updateForm(formId, data.formData);
    } finally {
      if (data.fd >= 0) {
        try {
          fileIo.closeSync(data.fd);
        } catch (err) {
          // fd 已失效可忽略
        }
      }
    }
  }
}
