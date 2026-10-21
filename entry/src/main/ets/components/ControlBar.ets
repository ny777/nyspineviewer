/**
 * 播放页悬浮控制条（单行全图标式）：槽位显隐开关（主/副紧凑单字，
 * 点按=显示/隐藏对应模型、长按=切换控制目标）/
 * 皮肤多选 + 动画菜单（中部横向滚动，动画 chip 置于最右）/
 * 播放暂停图标 / 截图（SaveButton 安全组件，点击临时授权直存系统图库）/
 * 重置变换图标 / 清空当前槽位图标。
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
  @Prop slot0Visible: boolean = true;
  @Prop slot1Visible: boolean = true;
  @StorageProp('themeDark') themeDark: boolean = true;

  onSlotChange: (slot: number) => void = (slot: number) => {
  };
  onSlotToggleVisible: (slot: number) => void = (slot: number) => {
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
    Row({ space: 6 }) {
      // 槽位显隐开关：主/副紧凑单字拼接 pill
      // 点按=切换该模型显隐（隐藏态变淡）；长按=切换控制目标（选中态高亮）
      Text($r('app.string.slot_main_short'))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width(32)
        .height(32)
        .backgroundColor(this.slot === 0 ? this.theme().cardSelected : this.theme().chip)
        .fontColor(this.slot === 0 ? Color.White : this.theme().textSecondary)
        .borderRadius({ topLeft: 16, bottomLeft: 16 })
        .opacity(this.slot0Visible ? 1 : 0.45)
        .accessibilityText($r('app.string.a11y_slot_vis_main'))
        .onClick(() => {
          this.onSlotToggleVisible(0);
        })
        .gesture(LongPressGesture({ repeat: false })
          .onAction(() => {
            this.onSlotChange(0);
          }))
      Text($r('app.string.slot_sub_short'))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width(32)
        .height(32)
        .backgroundColor(this.slot === 1 ? this.theme().cardSelected : this.theme().chip)
        .fontColor(this.slot === 1 ? Color.White : this.theme().textSecondary)
        .borderRadius({ topRight: 16, bottomRight: 16 })
        .opacity(this.slot1Visible ? 1 : 0.45)
        .accessibilityText($r('app.string.a11y_slot_vis_sub'))
        .onClick(() => {
          this.onSlotToggleVisible(1);
        })
        .gesture(LongPressGesture({ repeat: false })
          .onAction(() => {
            this.onSlotChange(1);
          }))

      // 中部弹性区：皮肤 chips + 动画 chip（最右），空间不足时可滚动
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.skins, (name: string) => {
            Text(name)
              .fontSize(12)
              .maxLines(1)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(13)
              .backgroundColor(this.selectedSkins.includes(name) ? this.theme().cardSelected : this.theme().chip)
              .fontColor(this.selectedSkins.includes(name) ? Color.White : this.theme().textSecondary)
              .onClick(() => {
                this.onSkinToggle(name);
              })
          }, (name: string) => name)
          Text(this.currentAnimation.length > 0 ? this.currentAnimation : $r('app.string.no_animation'))
            .fontSize(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 90 })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(13)
            .backgroundColor(this.theme().chip)
            .fontColor(this.theme().text)
            .bindMenu(this.AnimationMenuBuilder)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)

      // 播放/暂停图标
      Button() {
        SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(16)
          .fontColor([this.theme().text])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.theme().chip)
      .padding(0)
      .accessibilityText(this.playing ? $r('app.string.pause') : $r('app.string.play'))
      .onClick(() => {
        this.onTogglePlay();
      })

      // 截图（SaveButton 安全组件：点击临时授权，直存系统图库）
      SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Capsule })
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.onCapture();
          }
        })

      // 重置变换图标
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(16)
          .fontColor([this.theme().text])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.theme().chip)
      .padding(0)
      .accessibilityText($r('app.string.reset_transform'))
      .onClick(() => {
        this.onResetTransform();
      })

      // 清空当前槽位图标
      Button() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(16)
          .fontColor([this.theme().danger])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.theme().chip)
      .padding(0)
      .accessibilityText(this.slot === 0 ? $r('app.string.clear_main_model') : $r('app.string.clear_sub_model'))
      .onClick(() => {
        this.onClearSlot();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(20)
    .backgroundColor(this.theme().bottomBarBg)
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
