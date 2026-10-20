/**
 * 模型缩略图存取：<files>/thumbs/<modelId>.png，宽 360 等比缩放。
 * 截帧 base64 PNG 解码 → image kit 缩放 → ImagePacker 落盘；读写删均为同步轻量 IO。
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';

const THUMB_WIDTH = 360;

export class ThumbStore {
  static thumbDir(context: Context): string {
    return `${context.filesDir}/thumbs`;
  }

  static thumbPath(context: Context, modelId: string): string {
    return `${ThumbStore.thumbDir(context)}/${modelId}.png`;
  }

  /** 模型是否已有缩略图（文件存在性检查）。 */
  static hasThumb(context: Context, modelId: string): boolean {
    try {
      return fileIo.accessSync(ThumbStore.thumbPath(context, modelId), fileIo.AccessModeType.EXIST);
    } catch (err) {
      return false;
    }
  }

  /** 删除模型缩略图（不存在或失败均静默）。 */
  static deleteThumb(context: Context, modelId: string): void {
    try {
      fileIo.unlinkSync(ThumbStore.thumbPath(context, modelId));
    } catch (err) {
      // 清理失败不阻断流程
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
