/**
 * 模型库页（HdsTabs 第二页）：标题行 + 回收站入口 + 右上角导入（+ 图标 / 导入中取消胶囊）、
 * 置顶搜索栏（清空 / 一键折叠全部 / 排序菜单 / 管理入口）、分组列表（折叠 + 组操作菜单）、
 * 批量模式（勾选 + 工具栏：全选/已选/删除/完成）、模型卡片（版本/格式徽章、分组快捷移动）、
 * 设为主/副模型、重命名、删除（移入回收站）、空库三步引导卡。
 */
import { SpineModelItem } from '../model/SpineModelItem';
import { getTheme, ThemeColors } from '../core/Theme';
import { LibRow, LibraryListDataSource, ModelGroup } from './LibraryDataSource';

@Component
export struct ModelLibraryPage {
  /** 列表渲染输入全部经 @Watch 汇入 onLibraryInputChanged → dataSource.rebuild（LazyForEach 不观察状态）。 */
  @Link @Watch('onLibraryInputChanged') models: Array<SpineModelItem>;
  @Prop @Watch('onLibraryInputChanged') mainModelId: string = '';
  @Prop @Watch('onLibraryInputChanged') subModelId: string = '';
  @Prop importing: boolean = false;
  /** 批量导入进度（"done/total"，空串表示无进度）。 */
  @Prop importProgress: string = '';
  /** 缩略图补全管线运行中（横幅显示进度）。 */
  @Prop thumbGenerating: boolean = false;
  @Prop thumbGenCurrent: number = 0;
  @Prop thumbGenTotal: number = 0;
  onGenerateThumbs: (ids: Array<string>) => void = (ids: Array<string>) => {
  };
  onImport: () => void = () => {
  };
  onSelectMain: (modelId: string) => void = (modelId: string) => {
  };
  onSelectSub: (modelId: string) => void = (modelId: string) => {
  };
  onDelete: (modelId: string) => void = (modelId: string) => {
  };
  onMoveToGroup: (modelId: string) => void = (modelId: string) => {
  };
  onDissolveGroup: (group: string) => void = (group: string) => {
  };
  onDeleteGroup: (group: string) => void = (group: string) => {
  };
  onRenameGroup: (group: string) => void = (group: string) => {
  };
  onDeleteModels: (ids: Array<string>) => void = (ids: Array<string>) => {
  };
  onOpenTrash: () => void = () => {
  };
  onRenameModel: (modelId: string) => void = (modelId: string) => {
  };
  onSortChange: (mode: string) => void = (mode: string) => {
  };
  /** 库内排序模式：'default' | 'name' | 'time'。 */
  @Prop @Watch('onLibraryInputChanged') sortMode: string = 'default';
  /** 回收站内模型数（标题行徽标）。 */
  @Prop trashCount: number = 0;
  @State @Watch('onLibraryInputChanged') collapsedGroups: Array<string> = [];
  /** 批量管理模式（勾选删除）。 */
  @State @Watch('onLibraryInputChanged') batchMode: boolean = false;
  /** 批量模式已勾选的模型 id。 */
  @State @Watch('onLibraryInputChanged') selectedIds: Array<string> = [];
  /** 库内搜索关键字（名称/分组/版本/动画 substring 过滤）。 */
  @State @Watch('onLibraryInputChanged') searchQuery: string = '';
  /** 缺图横幅本次会话是否已忽略。 */
  @State thumbBannerDismissed: boolean = false;
  @StorageProp('themeDark') themeDark: boolean = true;
  /** 状态栏避让高度（沉浸式全屏，Index 动态下发）。 */
  @Prop topInsetVp: number = 0;
  /** 导航条手势区避让高度（沉浸式全屏，Index 动态下发）。 */
  @Prop bottomInsetVp: number = 0;

  /** LazyForEach 扁平行数据源（分组头 + 一行两卡），rebuild 后按 key 差分复用未变行。 */
  private dataSource: LibraryListDataSource = new LibraryListDataSource();
  /** 过滤结果缓存（键：models 引用 + 搜索词 + 排序模式）。 */
  private filterCacheSource: Array<SpineModelItem> | null = null;
  private filterCacheQuery: string = '';
  private filterCacheSort: string = '';
  private filterCacheResult: Array<SpineModelItem> = [];
  /** 分组视图缓存（键：过滤结果数组引用）。 */
  private groupsCacheSource: Array<SpineModelItem> | null = null;
  private groupsCacheResult: Array<ModelGroup> = [];

  aboutToAppear(): void {
    this.onLibraryInputChanged();
  }

  /** 全部列表输入（模型/排序/搜索/折叠/勾选/主副/批量）变化的统一重建入口。 */
  private onLibraryInputChanged(): void {
    this.dataSource.rebuild(this.buildGroups(), this.collapsedGroups,
      this.searchQuery.trim().length > 0, this.selectedIds,
      this.mainModelId, this.subModelId, this.batchMode);
  }

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  /** 搜索过滤：名称/分组/版本/动画任一 substring 命中（大小写不敏感）；再按排序模式排序（拷贝后排序，不就地改 models）。结果缓存：同一 models 引用 + 搜索词 + 排序模式直接复用。 */
  private filteredModels(): Array<SpineModelItem> {
    if (this.models === this.filterCacheSource && this.searchQuery === this.filterCacheQuery
      && this.sortMode === this.filterCacheSort) {
      return this.filterCacheResult;
    }
    const q = this.searchQuery.trim().toLowerCase();
    let source = this.models;
    if (q.length > 0) {
      source = this.models.filter((m: SpineModelItem): boolean =>
        m.name.toLowerCase().includes(q) ||
        m.group.toLowerCase().includes(q) ||
        m.version.toLowerCase().includes(q) ||
        m.animations.some((a: string): boolean => a.toLowerCase().includes(q)));
    }
    const sorted = source.slice();
    if (this.sortMode === 'name') {
      sorted.sort((a: SpineModelItem, b: SpineModelItem): number => {
        const an = a.name.toLowerCase();
        const bn = b.name.toLowerCase();
        return an < bn ? -1 : (an > bn ? 1 : 0);
      });
    } else if (this.sortMode === 'time') {
      sorted.sort((a: SpineModelItem, b: SpineModelItem): number => b.createdAt - a.createdAt);
    }
    this.filterCacheSource = this.models;
    this.filterCacheQuery = this.searchQuery;
    this.filterCacheSort = this.sortMode;
    this.filterCacheResult = sorted;
    return sorted;
  }

  /** 由模型列表派生分组视图：未分组置顶，其余按首现顺序（结果按过滤结果引用缓存）。 */
  private buildGroups(): Array<ModelGroup> {
    const src = this.filteredModels();
    if (src === this.groupsCacheSource) {
      return this.groupsCacheResult;
    }
    let ungrouped: ModelGroup | null = null;
    const named = new Map<string, ModelGroup>();
    for (const m of src) {
      if (m.group.length === 0) {
        if (ungrouped === null) {
          ungrouped = new ModelGroup('', new Array<SpineModelItem>());
        }
        ungrouped.models.push(m);
      } else {
        let bucket = named.get(m.group);
        if (bucket === undefined) {
          bucket = new ModelGroup(m.group, new Array<SpineModelItem>());
          named.set(m.group, bucket);
        }
        bucket.models.push(m);
      }
    }
    const result = new Array<ModelGroup>();
    if (ungrouped !== null) {
      result.push(ungrouped);
    }
    named.forEach((bucket: ModelGroup) => {
      result.push(bucket);
    });
    this.groupsCacheSource = src;
    this.groupsCacheResult = result;
    return result;
  }

  private isCollapsed(groupName: string): boolean {
    return this.collapsedGroups.indexOf(groupName) >= 0;
  }

  private toggleCollapse(groupName: string): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      const idx = this.collapsedGroups.indexOf(groupName);
      if (idx >= 0) {
        this.collapsedGroups.splice(idx, 1);
      } else {
        this.collapsedGroups.push(groupName);
      }
    });
  }

  /** 全部分组是否都处于折叠态。 */
  private allGroupsCollapsed(): boolean {
    const groups = this.buildGroups();
    if (groups.length === 0) {
      return true;
    }
    for (const g of groups) {
      if (!this.isCollapsed(g.name)) {
        return false;
      }
    }
    return true;
  }

  /** 一键折叠/展开全部分组：任一展开 → 全折叠；全折叠 → 全展开。 */
  private toggleCollapseAll(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      if (this.allGroupsCollapsed()) {
        this.collapsedGroups = [];
        return;
      }
      const names = new Array<string>();
      for (const g of this.buildGroups()) {
        names.push(g.name);
      }
      this.collapsedGroups = names;
    });
  }

  // ==================== 批量管理模式 ====================

  private enterBatch(): void {
    this.selectedIds = [];
    this.batchMode = true;
  }

  private exitBatch(): void {
    this.batchMode = false;
    this.selectedIds = [];
  }

  private isSelected(modelId: string): boolean {
    return this.selectedIds.indexOf(modelId) >= 0;
  }

  /** 当前过滤结果是否已全部勾选。 */
  private isFilteredAllSelected(): boolean {
    const filtered = this.filteredModels();
    if (filtered.length === 0) {
      return false;
    }
    for (const m of filtered) {
      if (!this.isSelected(m.id)) {
        return false;
      }
    }
    return true;
  }

  /** 全选/取消全选（仅作用于当前过滤结果）。 */
  private toggleSelectAll(): void {
    const filtered = this.filteredModels();
    if (this.isFilteredAllSelected()) {
      const remaining = new Array<string>();
      for (const id of this.selectedIds) {
        const stillVisible = filtered.some((m: SpineModelItem): boolean => m.id === id);
        if (!stillVisible) {
          remaining.push(id);
        }
      }
      this.selectedIds = remaining;
      return;
    }
    const next = this.selectedIds.slice();
    for (const m of filtered) {
      if (next.indexOf(m.id) < 0) {
        next.push(m.id);
      }
    }
    this.selectedIds = next;
  }

  private toggleSelect(modelId: string): void {
    const idx = this.selectedIds.indexOf(modelId);
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1);
    } else {
      this.selectedIds.push(modelId);
    }
  }

  /** 缺少缩略图且可渲染的模型（横幅计数与生成入参）。 */
  private modelsMissingThumb(): Array<SpineModelItem> {
    const result = new Array<SpineModelItem>();
    for (const m of this.models) {
      if (!m.hasThumb && m.isSupported()) {
        result.push(m);
      }
    }
    return result;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text($r('app.string.drawer_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .maxLines(1)
          .layoutWeight(1)

        Button() {
          Stack() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(18)
              .fontColor([this.theme().textSecondary])
            if (this.trashCount > 0) {
              Text(`${this.trashCount}`)
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor(this.theme().danger)
                .borderRadius(7)
                .constraintSize({ minWidth: 14 })
                .height(14)
                .padding({ left: 3, right: 3 })
                .textAlign(TextAlign.Center)
                .offset({ x: 9, y: -9 })
            }
          }
          .width(24)
          .height(24)
        }
        .width(38)
        .height(38)
        .borderRadius(19)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .margin({ left: 8 })
        .accessibilityText($r('app.string.trash_a11y'))
        .onClick(() => {
          this.onOpenTrash();
        })

        if (!this.importing) {
          Button() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.theme().importBtn)
          .padding(0)
          .accessibilityText($r('app.string.import_model'))
          .onClick(() => {
            this.onImport();
          })
        } else {
          Button(this.importProgress.length > 0
            ? $r('app.string.cancel_import_progress', this.importProgress)
            : $r('app.string.btn_cancel_import'))
            .height(38)
            .borderRadius(19)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .backgroundColor(this.theme().danger)
            .fontColor(Color.White)
            .onClick(() => {
              this.onImport();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.batchMode) {
        this.BatchToolbar()
      } else if (this.models.length > 0) {
        Row({ space: 8 }) {
          TextInput({ text: this.searchQuery, placeholder: $r('app.string.search_hint') })
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor(this.theme().text)
            .backgroundColor(this.theme().chip)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.searchQuery = value;
            })
          if (this.searchQuery.length > 0) {
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([this.theme().textSecondary])
            }
            .width(38)
            .height(38)
            .borderRadius(19)
            .backgroundColor(this.theme().chip)
            .padding(0)
            .accessibilityText($r('app.string.search_clear'))
            .onClick(() => {
              this.searchQuery = '';
            })
          }
          Button() {
            SymbolGlyph(this.allGroupsCollapsed() ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(16)
              .fontColor([this.theme().textSecondary])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.theme().chip)
          .padding(0)
          .accessibilityText(this.allGroupsCollapsed()
            ? $r('app.string.expand_all')
            : $r('app.string.collapse_all'))
          .onClick(() => {
            this.toggleCollapseAll();
          })
          Button() {
            SymbolGlyph($r('sys.symbol.sort'))
              .fontSize(16)
              .fontColor([this.theme().textSecondary])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.theme().chip)
          .padding(0)
          .accessibilityText($r('app.string.sort_a11y'))
          .bindMenu(this.SortMenu)
          Button($r('app.string.batch_manage'))
            .height(38)
            .borderRadius(19)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .backgroundColor(this.theme().chip)
            .fontColor(this.theme().text)
            .onClick(() => {
              this.enterBatch();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (!this.batchMode &&
        (this.thumbGenerating || (!this.thumbBannerDismissed && this.modelsMissingThumb().length > 0))) {
        this.ThumbBanner()
      }

      if (this.models.length === 0) {
        this.EmptyGuide()
      } else if (this.searchQuery.trim().length > 0 && this.filteredModels().length === 0) {
        Column() {
          Text($r('app.string.search_empty'))
            .fontSize(14)
            .fontColor(this.theme().textMuted)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 10 }) {
          LazyForEach(this.dataSource, (row: LibRow) => {
            ListItem() {
              if (row.isHeader) {
                this.GroupHeader(row)
              } else {
                this.PairRow(row)
              }
            }
          }, (row: LibRow) => row.key)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16 + this.topInsetVp, bottom: 100 + this.bottomInsetVp })
    .backgroundColor(this.theme().pageBg)
  }

  /** 排序菜单：当前模式项高亮，点击即应用并关闭。 */
  @Builder
  SortMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.sort_default') })
        .contentFontColor(this.sortMode === 'default' ? this.theme().accent : this.theme().text)
        .onClick(() => {
          this.onSortChange('default');
        })
      MenuItem({ content: $r('app.string.sort_name') })
        .contentFontColor(this.sortMode === 'name' ? this.theme().accent : this.theme().text)
        .onClick(() => {
          this.onSortChange('name');
        })
      MenuItem({ content: $r('app.string.sort_time') })
        .contentFontColor(this.sortMode === 'time' ? this.theme().accent : this.theme().text)
        .onClick(() => {
          this.onSortChange('time');
        })
    }
  }

  /** 批量模式工具栏：全选 | 已选 n | 删除 | 完成（替换搜索行）。 */
  @Builder
  BatchToolbar() {    Row({ space: 10 }) {
      Row({ space: 6 }) {
        Checkbox()
          .select(this.isFilteredAllSelected())
          .selectedColor(this.theme().cardSelected)
          .width(20)
          .height(20)
          .hitTestBehavior(HitTestMode.None)
        Text($r('app.string.batch_select_all'))
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleSelectAll();
      })

      Text($r('app.string.batch_selected_count', this.selectedIds.length))
        .fontSize(12)
        .fontColor(this.theme().textMuted)
        .maxLines(1)
        .layoutWeight(1)

      Button($r('app.string.batch_delete'))
        .height(34)
        .fontSize(13)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.theme().danger)
        .fontColor(Color.White)
        .enabled(this.selectedIds.length > 0)
        .opacity(this.selectedIds.length > 0 ? 1 : 0.5)
        .onClick(() => {
          if (this.selectedIds.length === 0) {
            return;
          }
          const ids = this.selectedIds.slice();
          this.getUIContext().showAlertDialog({
            message: $r('app.string.batch_move_to_trash_confirm', ids.length),
            primaryButton: {
              value: $r('app.string.dialog_cancel'),
              action: (): void => {
              }
            },
            secondaryButton: {
              value: $r('app.string.dialog_delete'),
              fontColor: this.theme().danger,
              action: (): void => {
                this.exitBatch();
                this.onDeleteModels(ids);
              }
            }
          });
        })

      Button($r('app.string.batch_done'))
        .height(34)
        .fontSize(13)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().text)
        .onClick(() => {
          this.exitBatch();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 缺图补全横幅：缺 N 个 → 生成/忽略；生成中 → 进度文本。 */
  @Builder
  ThumbBanner() {
    Row({ space: 8 }) {
      if (this.thumbGenerating) {
        Text($r('app.string.thumb_generating', this.thumbGenCurrent, this.thumbGenTotal))
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
          .maxLines(1)
      } else {
        Text($r('app.string.thumb_banner_text', this.modelsMissingThumb().length))
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
          .maxLines(1)
        Button($r('app.string.thumb_banner_generate'))
          .height(28)
          .fontSize(12)
          .padding({ left: 14, right: 14 })
          .backgroundColor(this.theme().importBtn)
          .fontColor(Color.White)
          .onClick(() => {
            const ids = new Array<string>();
            for (const m of this.modelsMissingThumb()) {
              ids.push(m.id);
            }
            this.onGenerateThumbs(ids);
          })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(12)
            .fontColor([this.theme().textSecondary])
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .accessibilityText($r('app.string.search_clear'))
        .onClick(() => {
          this.thumbBannerDismissed = true;
        })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.theme().card)
    .alignItems(VerticalAlign.Center)
  }

  /** 空库三步引导卡：标题 + 三步说明 + 大号导入按钮。 */
  @Builder
  EmptyGuide() {
    Column({ space: 14 }) {
      Column({ space: 10 }) {
        Text($r('app.string.empty_guide_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .textAlign(TextAlign.Center)
        Column({ space: 8 }) {
          Text($r('app.string.empty_guide_step1'))
          Text($r('app.string.empty_guide_step2'))
          Text($r('app.string.empty_guide_step3'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
        .borderRadius(12)
        .backgroundColor(this.theme().card)
      }
      .alignItems(HorizontalAlign.Center)

      Button($r('app.string.empty_guide_btn'))
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor(this.theme().importBtn)
        .fontColor(Color.White)
        .onClick(() => {
          this.onImport();
        })
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .width('100%')
  }

  /** 分组头：折叠箭头 + 名称 + 数量 + 组操作 ⋮ 菜单。 */
  @Builder
  GroupHeader(row: LibRow) {
    Row({ space: 8 }) {
      SymbolGlyph(this.isCollapsed(row.headerName) ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([this.theme().textSecondary])
        .width(16)
      Text(row.headerName.length === 0 ? $r('app.string.group_ungrouped') : row.headerName)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${row.headerCount}`)
        .fontSize(11)
        .fontColor(this.theme().badgeText)
        .backgroundColor(this.theme().badgeBg)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
      if (row.headerName.length > 0) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(14)
          .fontColor([this.theme().textSecondary])
          .width(24)
          .bindMenu([
            {
              value: $r('app.string.menu_rename_group'),
              action: (): void => {
                this.onRenameGroup(row.headerName);
              }
            },
            {
              value: $r('app.string.menu_dissolve_group'),
              action: (): void => {
                this.onDissolveGroup(row.headerName);
              }
            },
            {
              value: $r('app.string.menu_delete_group'),
              action: (): void => {
                this.onDeleteGroup(row.headerName);
              }
            }
          ])
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .onClick(() => {
      this.toggleCollapse(row.headerName);
    })
  }

  /** 一行两卡：每行两个等宽卡片，奇数行右侧留占位。 */
  @Builder
  PairRow(row: LibRow) {
    Row({ space: 10 }) {
      Column() {
        this.ModelCard(row.items[0])
      }
      .layoutWeight(1)
      if (row.items.length > 1) {
        Column() {
          this.ModelCard(row.items[1])
        }
        .layoutWeight(1)
      } else {
        Column()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 卡片缩略图（64x84 圆角 8）：有图显示 file 图，无图占位；批量勾选叠加左上角。 */
  @Builder
  ThumbImage(model: SpineModelItem) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (model.hasThumb) {
        Image(`file://${getContext(this).filesDir}/thumbs/${model.id}.png`)
          .width(64)
          .height(84)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .interpolation(ImageInterpolation.Medium)
          .autoResize(true)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(22)
            .fontColor([this.theme().textMuted])
        }
        .width(64)
        .height(84)
        .borderRadius(8)
        .backgroundColor(this.theme().chip)
        .justifyContent(FlexAlign.Center)
      }
      if (this.batchMode) {
        Checkbox()
          .select(this.isSelected(model.id))
          .selectedColor(this.theme().cardSelected)
          .width(18)
          .height(18)
          .margin(4)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(64)
  }

  @Builder
  ModelCard(model: SpineModelItem) {
    Row({ space: 10 }) {
      this.ThumbImage(model)
      Column({ space: 6 }) {
        Text(model.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(model.version)
            .fontSize(10)
            .fontColor(this.theme().badgeText)
            .backgroundColor(this.theme().badgeBg)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
          Text(model.format)
            .fontSize(10)
            .fontColor(this.theme().badgeText)
            .backgroundColor(this.theme().badgeBg)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
          if (!model.isSupported()) {
            Text($r('app.string.badge_unsupported'))
              .fontSize(10)
              .fontColor(this.theme().badgeWarnText)
              .backgroundColor(this.theme().badgeWarnBg)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
          }
          Text(model.group.length > 0 ? model.group : $r('app.string.group_ungrouped'))
            .fontSize(10)
            .fontColor(this.theme().textSecondary)
            .backgroundColor(this.theme().chip)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 96 })
            .flexShrink(1)
            .onClick(() => {
              if (!this.batchMode) {
                this.onMoveToGroup(model.id);
              }
            })
        }
        .alignItems(VerticalAlign.Center)
        if (!this.batchMode) {
          Row({ space: 6 }) {
            Button($r('app.string.set_main_short'))
              .layoutWeight(1)
              .fontSize(12)
              .height(28)
              .backgroundColor(model.id === this.mainModelId ? this.theme().cardSelected : this.theme().chip)
              .fontColor(model.id === this.mainModelId ? Color.White : this.theme().textSecondary)
              .accessibilityText($r('app.string.set_main'))
              .onClick(() => {
                this.onSelectMain(model.id);
              })
            Button($r('app.string.set_sub_short'))
              .layoutWeight(1)
              .fontSize(12)
              .height(28)
              .backgroundColor(model.id === this.subModelId ? this.theme().cardSelected : this.theme().chip)
              .fontColor(model.id === this.subModelId ? Color.White : this.theme().textSecondary)
              .accessibilityText($r('app.string.set_sub'))
              .onClick(() => {
                this.onSelectSub(model.id);
              })
          }
          .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!this.batchMode) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(12)
            .fontColor([this.theme().textSecondary])
        }
        .width(24)
        .height(24)
        .borderRadius(12)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .accessibilityText($r('app.string.a11y_delete_model'))
        .onClick(() => {
          this.onDelete(model.id);
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .borderRadius(12)
    .backgroundColor(this.theme().card)
    .border({
      width: 2,
      color: this.batchMode && this.isSelected(model.id) ? this.theme().cardSelected : Color.Transparent
    })
    .onClick(() => {
      if (this.batchMode) {
        this.toggleSelect(model.id);
      }
    })
    .bindContextMenuByResponseType(this.cardMenuItems(model), ResponseType.LongPress)
  }

  /** 长按模型卡片快捷菜单项：设为主/设为副/移动分组/删除（批量模式下返回空数组不弹菜单）。 */
  private cardMenuItems(model: SpineModelItem): Array<MenuElement> {
    if (this.batchMode) {
      return [];
    }
    return [
      {
        value: $r('app.string.set_main'),
        action: (): void => {
          this.onSelectMain(model.id);
        }
      },
      {
        value: $r('app.string.set_sub'),
        action: (): void => {
          this.onSelectSub(model.id);
        }
      },
      {
        value: $r('app.string.menu_move_group'),
        action: (): void => {
          this.onMoveToGroup(model.id);
        }
      },
      {
        value: $r('app.string.menu_rename_model'),
        action: (): void => {
          this.onRenameModel(model.id);
        }
      },
      {
        value: $r('app.string.dialog_delete'),
        action: (): void => {
          this.onDelete(model.id);
        }
      }
    ];
  }
}
