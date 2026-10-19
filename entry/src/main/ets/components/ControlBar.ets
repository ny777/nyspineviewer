/**
 * 播放页悬浮控制条：槽位切换 / 播放暂停 / 截帧 / 重置变换 / 动画菜单 /
 * 皮肤多选。PMA、帧率与背景设置在设置页；状态与持久化由父页面持有。
 */
import { getTheme, ThemeColors } from '../core/Theme';

@Component
export struct ControlBar {
  @Prop slot: number = 0;
  @Prop playing: boolean = true;
  @Prop capturing: boolean = false;
  @Prop animations: Array<string> = [];
  @Prop currentAnimation: string = '';
  @Prop skins: Array<string> = [];
  @Prop selectedSkins: Array<string> = [];
  @StorageProp('themeDark') themeDark: boolean = true;

  onSlotChange: (slot: number) => void = (slot: number) => {
  };
  onTogglePlay: () => void = () => {
  };
  onAnimationPick: (name: string) => void = (name: string) => {
  };
  onSkinToggle: (name: string) => void = (name: string) => {
  };
  onCapture: () => void = () => {
  };
  onResetTransform: () => void = () => {
  };
  onClearSlot: () => void = () => {
  };

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 10 }) {
      // 行1：槽位 / 播放 / 截帧 / 重置变换
      Row({ space: 8 }) {
        Row() {
          Text($r('app.string.slot_main'))
            .fontSize(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.slot === 0 ? this.theme().cardSelected : this.theme().chip)
            .fontColor(this.slot === 0 ? Color.White : this.theme().textSecondary)
            .borderRadius({ topLeft: 14, bottomLeft: 14 })
            .onClick(() => {
              this.onSlotChange(0);
            })
          Text($r('app.string.slot_sub'))
            .fontSize(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.slot === 1 ? this.theme().cardSelected : this.theme().chip)
            .fontColor(this.slot === 1 ? Color.White : this.theme().textSecondary)
            .borderRadius({ topRight: 14, bottomRight: 14 })
            .onClick(() => {
              this.onSlotChange(1);
            })
        }
        .alignItems(VerticalAlign.Center)

        Button(this.playing ? $r('app.string.pause') : $r('app.string.play'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().text)
          .onClick(() => {
            this.onTogglePlay();
          })

        Button($r('app.string.capture'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.theme().accent)
          .fontColor(Color.White)
          .enabled(!this.capturing)
          .onClick(() => {
            this.onCapture();
          })

        Button($r('app.string.reset_transform'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().text)
          .onClick(() => {
            this.onResetTransform();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 行2：动画 + 皮肤 + 清空当前槽位模型（合并单行）
      Row({ space: 10 }) {
        Text($r('app.string.animation_label'))
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
        Text(this.currentAnimation.length > 0 ? this.currentAnimation : $r('app.string.no_animation'))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 160 })
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().text)
          .bindMenu(this.AnimationMenuBuilder)
        if (this.skins.length > 0) {
          Text($r('app.string.skins_label'))
            .fontSize(12)
            .fontColor(this.theme().textSecondary)
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.skins, (name: string) => {
                Text(name)
                  .fontSize(12)
                  .maxLines(1)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .borderRadius(13)
                  .backgroundColor(this.selectedSkins.includes(name) ? this.theme().cardSelected : this.theme().chip)
                  .fontColor(this.selectedSkins.includes(name) ? Color.White : this.theme().textSecondary)
                  .onClick(() => {
                    this.onSkinToggle(name);
                  })
              }, (name: string) => name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        } else {
          Blank()
            .layoutWeight(1)
        }
        Text(this.slot === 0 ? $r('app.string.clear_main_model') : $r('app.string.clear_sub_model'))
          .fontSize(12)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().danger)
          .onClick(() => {
            this.onClearSlot();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(20)
    .backgroundColor(this.theme().bottomBarBg)
    .width('100%')
  }

  @Builder
  AnimationMenuBuilder() {
    Menu() {
      ForEach(this.animations, (name: string) => {
        MenuItem({ content: name })
          .onClick(() => {
            this.onAnimationPick(name);
          })
      }, (name: string) => name)
    }
  }
}
