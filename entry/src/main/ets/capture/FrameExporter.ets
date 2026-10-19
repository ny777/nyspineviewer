/**
 * 截帧导出：WebView 回传的 base64 PNG 解码后写入沙箱临时文件，
 * 经 photoAccessHelper 资产变更请求直接入库系统图库（SaveButton 临时授权，免权限免弹窗）。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';

export class FrameExporter {
  /**
   * 把 base64 PNG 保存到系统图库（"图片"相册，图库 App 可见）。
   * @throws 保存失败抛 Error（message 可读）。
   */
  static async saveToGallery(context: Context, base64Png: string): Promise<void> {
    const bytes = new util.Base64Helper().decodeSync(base64Png);
    const tmpPath = `${context.cacheDir}/spine_capture_${Date.now()}.png`;
    const file = fileIo.openSync(tmpPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
      fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes.buffer);
    } finally {
      fileIo.closeSync(file);
    }
    try {
      const phHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const request = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context,
        `file://${tmpPath}`);
      await phHelper.applyChanges(request);
    } catch (err) {
      throw new Error(`保存截图到图库失败：${JSON.stringify(err)}`);
    } finally {
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (err) {
        // 临时文件清理失败可忽略
      }
    }
  }
}
