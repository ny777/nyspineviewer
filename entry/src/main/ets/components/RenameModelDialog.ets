/**
 * 模型重命名弹窗（@CustomDialog）：预填当前模型名，确定回调返回新名称
 * （空串或与原名相同由调用方短路）。允许与其他模型重名。
 */
import { getTheme, ThemeColors } from '../core/Theme';

@CustomDialog
export struct RenameModelDialog {
  controller?: CustomDialogController;
  initialName: string = '';
  confirm: (newName: string) => void = (newName: string) => {
  };
  @State newName: string = '';
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  aboutToAppear(): void {
    this.newName = this.initialName;
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.rename_model_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        .width('100%')

      Text(this.initialName)
        .fontSize(12)
        .fontColor(this.theme().textMuted)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      TextInput({ text: this.newName, placeholder: $r('app.string.rename_model_hint') })
        .width('100%')
        .fontSize(14)
        .fontColor(this.theme().text)
        .backgroundColor(this.theme().chip)
        .onChange((value: string) => {
          this.newName = value;
        })

      Row({ space: 12 }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().textSecondary)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.dialog_ok'))
          .layoutWeight(1)
          .backgroundColor(this.theme().accent)
          .fontColor(Color.White)
          .onClick(() => {
            const trimmed = this.newName.trim();
            this.controller?.close();
            if (trimmed.length > 0) {
              this.confirm(trimmed);
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('90%')
    .backgroundColor(this.theme().dialogBg)
    .borderRadius(16)
  }
}
