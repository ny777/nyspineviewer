/**
 * 模型缩略图存取：<files>/thumbs/<modelId>.png，宽 360 等比缩放。
 * 截帧 base64 PNG 解码 → image kit 缩放 → ImagePacker 落盘；读写删均为同步轻量 IO。
 * hasThumb 走进程内 Set 缓存（首查一次 listFileSync 建集，增删同步维护），避免数百次 stat。
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';

const THUMB_WIDTH = 360;

export class ThumbStore {
  /** 进程内缩略图 id 缓存（null = 未扫描）。 */
  private static scannedIds: Set<string> | null = null;

  /** 首次调用时一次 listFileSync 建集；之后增删同步维护，不再触碰磁盘。 */
  private static ensureScanned(context: Context): void {
    if (ThumbStore.scannedIds !== null) {
      return;
    }
    const ids = new Set<string>();
    try {
      const dir = ThumbStore.thumbDir(context);
      if (fileIo.accessSync(dir, fileIo.AccessModeType.EXIST)) {
        const names: Array<string> = fileIo.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          const name = names[i];
          if (name.endsWith('.png')) {
            ids.add(name.substring(0, name.length - 4));
          }
        }
      }
    } catch (err) {
      // 扫描失败按空集处理，后续 save/delete 仍会维护
    }
    ThumbStore.scannedIds = ids;
  }

  static thumbDir(context: Context): string {
    return `${context.filesDir}/thumbs`;
  }

  static thumbPath(context: Context, modelId: string): string {
    return `${ThumbStore.thumbDir(context)}/${modelId}.png`;
  }

  /** 模型是否已有缩略图（内存 Set 查找，零磁盘 IO）。 */
  static hasThumb(context: Context, modelId: string): boolean {
    ThumbStore.ensureScanned(context);
    return ThumbStore.scannedIds !== null && ThumbStore.scannedIds.has(modelId);
  }

  /** 删除模型缩略图（不存在或失败均静默；同步维护内存缓存）。 */
  static deleteThumb(context: Context, modelId: string): void {
    try {
      fileIo.unlinkSync(ThumbStore.thumbPath(context, modelId));
    } catch (err) {
      // 清理失败不阻断流程
    }
    ThumbStore.ensureScanned(context);
    if (ThumbStore.scannedIds !== null) {
      ThumbStore.scannedIds.delete(modelId);
    }
  }

  /**
   * 把截帧 base64 PNG 缩放为宽 360 的缩略图并落盘。
   * @throws 解码/缩放/写盘失败抛 Error，由调用方 catch 计数。
   */
  static async saveThumb(context: Context, base64Png: string, modelId: string): Promise<void> {
    const bytes = new util.Base64Helper().decodeSync(base64Png);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const source = image.createImageSource(buffer);
    try {
      const info = await source.getImageInfo();
      const ratio = THUMB_WIDTH / info.size.width;
      const pixelMap = await source.createPixelMap({
        desiredSize: {
          width: THUMB_WIDTH,
          height: Math.max(1, Math.round(info.size.height * ratio))
        }
      });
      try {
        const packer = image.createImagePacker();
        try {
          const data: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
          const dir = ThumbStore.thumbDir(context);
          if (!fileIo.accessSync(dir, fileIo.AccessModeType.EXIST)) {
            fileIo.mkdirSync(dir);
          }
          const file = fileIo.openSync(ThumbStore.thumbPath(context, modelId),
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            fileIo.writeSync(file.fd, data);
          } finally {
            fileIo.closeSync(file);
          }
          // 落盘成功后维护内存缓存（含首次建集）
          ThumbStore.ensureScanned(context);
          if (ThumbStore.scannedIds !== null) {
            ThumbStore.scannedIds.add(modelId);
          }
        } finally {
          packer.release();
        }
      } finally {
        pixelMap.release();
      }
    } finally {
      source.release();
    }
  }
}
