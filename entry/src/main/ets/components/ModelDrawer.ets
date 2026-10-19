/**
 * 左侧模型库抽屉：导入 ZIP、模型卡片列表（版本/格式徽章）、设为主/副模型、删除。
 */
import { SpineModelItem } from '../model/SpineModelItem';

@Component
export struct ModelDrawer {
  @Link models: Array<SpineModelItem>;
  @Prop mainModelId: string = '';
  @Prop subModelId: string = '';
  @Prop importing: boolean = false;
  onImport: () => void = () => {
  };
  onSelectMain: (modelId: string) => void = (modelId: string) => {
  };
  onSelectSub: (modelId: string) => void = (modelId: string) => {
  };
  onDelete: (modelId: string) => void = (modelId: string) => {
  };
  onClose: () => void = () => {
  };

  build() {
    Column({ space: 12 }) {
      Row() {
        Text($r('app.string.drawer_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('✕')
          .fontSize(18)
          .fontColor($r('app.color.text_secondary'))
          .padding(8)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Button(this.importing ? $r('app.string.importing') : $r('app.string.import_model'))
        .width('100%')
        .backgroundColor($r('app.color.primary'))
        .fontColor(Color.White)
        .enabled(!this.importing)
        .onClick(() => {
          this.onImport();
        })

      if (this.models.length === 0) {
        Column({ space: 10 }) {
          Text($r('app.string.empty_library_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          Text($r('app.string.empty_library_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 10 }) {
          ForEach(this.models, (model: SpineModelItem) => {
            ListItem() {
              this.ModelCard(model)
            }
          }, (model: SpineModelItem) => model.id)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.panel_bg'))
  }

  @Builder
  ModelCard(model: SpineModelItem) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(model.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(model.version)
              .fontSize(10)
              .fontColor($r('app.color.badge_text'))
              .backgroundColor($r('app.color.badge_bg'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
            Text(model.format)
              .fontSize(10)
              .fontColor($r('app.color.badge_text'))
              .backgroundColor($r('app.color.badge_bg'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
            if (!model.isSupported()) {
              Text($r('app.string.badge_unsupported'))
                .fontSize(10)
                .fontColor($r('app.color.badge_warn_text'))
                .backgroundColor($r('app.color.badge_warn_bg'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(4)
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('✕')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .padding(6)
          .onClick(() => {
            this.onDelete(model.id);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Button($r('app.string.set_main'))
          .layoutWeight(1)
          .fontSize(12)
          .height(32)
          .backgroundColor(model.id === this.mainModelId ? $r('app.color.primary') : $r('app.color.chip_bg'))
          .fontColor(model.id === this.mainModelId ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => {
            this.onSelectMain(model.id);
          })
        Button($r('app.string.set_sub'))
          .layoutWeight(1)
          .fontSize(12)
          .height(32)
          .backgroundColor(model.id === this.subModelId ? $r('app.color.primary') : $r('app.color.chip_bg'))
          .fontColor(model.id === this.subModelId ? Color.White : $r('app.color.text_secondary'))
          .onClick(() => {
            this.onSelectSub(model.id);
          })
      }
      .width('100%')
    }
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }
}
