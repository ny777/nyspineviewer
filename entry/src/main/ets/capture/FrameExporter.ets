/**
 * 截帧导出：WebView 回传的 base64 PNG 解码后经系统文档保存选择器落盘（免权限）。
 */
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';

export class FrameExporter {
  /**
   * 把 base64 PNG 保存到用户选择的位置。
   * @returns 保存目标 URI；用户取消返回空串。
   * @throws 写入失败抛 Error（message 可读）。
   */
  static async savePng(context: Context, base64Png: string): Promise<string> {
    const bytes = new util.Base64Helper().decodeSync(base64Png);
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [`spine_${Date.now()}.png`];
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.save(saveOptions);
    if (uris.length === 0) {
      return '';
    }
    const uri = uris[0];
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes.buffer);
    } finally {
      fileIo.closeSync(file);
    }
    return uri;
  }
}
