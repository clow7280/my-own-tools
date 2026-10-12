import AppKit
import StatsCore

// MARK: - 系统页

/// 占用率 / 温度 / 磁盘 / 网络四张卡片（设计稿 3a）
final class SystemPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0

    /// 峰值线显示阈值：窗口内的峰均差全部小于均值窗口平均值的 5% 时不画峰值线，
    /// 避免两条曲线几乎重合、只剩描边噪声
    private static let peakVisibilityRatio = 0.05

    /// 最近一次收到的历史，切换时长后不等下一秒采样就能立即重绘
    private var history: [StatsSample] = []
    /// 每张卡独立的时长档位与对应切换控件
    private var ranges: [SparklineRange.Slot: SparklineRange] = Dictionary(
        uniqueKeysWithValues: SparklineRange.Slot.allCases.map { ($0, SparklineRange.stored($0)) })
    private var rangeControls: [SparklineRange.Slot: SparklineRangeControl] = [:]

    // 占用率卡
    private let cpuSpark = SparklineView()
    private let gpuSpark = SparklineView()
    private let ramSpark = SparklineView()
    private let cpuValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let gpuValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let ramValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let cpuCoresInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let cpuLoadInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let ramInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 温度卡
    private let cpuTempSpark = SparklineView()
    private let gpuTempSpark = SparklineView()
    private let cpuTempValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let gpuTempValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let diskTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let batteryTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let memoryTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let socTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)

    // 磁盘卡
    private let readSpark = SparklineView()
    private let writeSpark = SparklineView()
    private let readValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let writeValue = PageUI.label(size: PageUI.rowValueSize, weight: .semibold, mono: true)
    private let readTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let writeTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 网络卡
    private let downValue = PageUI.label(size: 19, weight: .semibold)
    private let upValue = PageUI.label(size: 19, weight: .semibold)
    private let netSpark = SparklineView()
    private let interfaceValue = PageUI.label("—", size: 12, weight: .medium)
    private let localIPValue = PageUI.label("—", size: 12, weight: .medium, mono: true)
    private let publicIPValue = PageUI.label("—", size: 12, weight: .medium, mono: true)
    private let publicIP = PublicIPFetcher()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var y: CGFloat = 0
        y = buildUsageCard(top: y) + PageUI.cardGap
        y = buildTempCard(top: y) + PageUI.cardGap
        y = buildDiskCard(top: y) + PageUI.cardGap
        y = buildNetworkCard(top: y)
        contentHeight = y
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 建卡

    private func addCard(top: CGFloat, height: CGFloat) -> CardView {
        let card = CardView()
        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: height)
        addSubview(card)
        return card
    }

    /// 卡片标题行：左标题 + 右侧本卡的 sparkline 时长胶囊。
    /// 胶囊高 15 顶边 7，与 y=8 高 14 的标题视觉居中对齐，且不越到 y=30 的内容区
    private func addHeader(_ title: String, in card: CardView, slot: SparklineRange.Slot) {
        let header = PageUI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        header.frame = NSRect(x: PageUI.cardPadding, y: 8, width: 120, height: 14)
        card.addSubview(header)

        let control = SparklineRangeControl(trailingX: PageUI.pageWidth - PageUI.cardPadding,
                                            topY: 7) { [weak self] picked in
            self?.selectRange(picked, for: slot)
        }
        control.range = range(slot)
        card.addSubview(control)
        rangeControls[slot] = control
    }

    private func range(_ slot: SparklineRange.Slot) -> SparklineRange { ranges[slot] ?? .oneMinute }

    /// 把该卡切到选中的档位：写回 UserDefaults、更新本卡文案，并立即用缓存历史只重绘本卡
    private func selectRange(_ picked: SparklineRange, for slot: SparklineRange.Slot) {
        guard range(slot) != picked else { return }
        ranges[slot] = picked
        SparklineRange.store(picked, for: slot)
        rangeControls[slot]?.range = picked
        guard let last = history.last else { return }
        switch slot {
        case .usage: updateUsageCard(last)
        case .temperature: updateTempCard(last)
        case .disk: updateDiskCard(last)
        case .network: updateNetworkCard(last)
        }
    }

    /// 指标行：标签 | sparkline | 数值；返回行底
    @discardableResult
    private func addMetricRow(_ title: String, spark: SparklineView, sparkHeight: CGFloat,
                              value: NSTextField, y: CGFloat,
                              rowHeight: CGFloat, in card: CardView) -> CGFloat {
        let name = PageUI.label(title, size: 12, weight: .semibold)
        name.frame = NSRect(x: PageUI.cardPadding, y: y + (rowHeight - 15) / 2,
                            width: PageUI.rowLabelWidth, height: 15)
        card.addSubview(name)

        let sparkX = PageUI.cardPadding + PageUI.rowLabelWidth + PageUI.rowGap
        let sparkWidth = PageUI.innerWidth - PageUI.rowLabelWidth - PageUI.rowValueWidth - PageUI.rowGap * 2
        spark.frame = NSRect(x: sparkX, y: y + (rowHeight - sparkHeight) / 2,
                             width: sparkWidth, height: sparkHeight)
        card.addSubview(spark)

        value.alignment = .right
        value.frame = NSRect(x: sparkX + sparkWidth + PageUI.rowGap, y: y + (rowHeight - 17) / 2,
                             width: PageUI.rowValueWidth, height: 17)
        card.addSubview(value)
        return y + rowHeight
    }

    private func buildUsageCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30    // 标题行 8+14，与内容间距 8
        let subIndent = PageUI.cardPadding + PageUI.rowLabelWidth + PageUI.rowGap

        let card = CardView()
        for spark in [cpuSpark, gpuSpark, ramSpark] { spark.scaleFormat = .percent }

        y = addMetricRow("CPU", spark: cpuSpark, sparkHeight: 24, value: cpuValue,
                         y: y, rowHeight: 24, in: card)
        cpuCoresInfo.alignment = .right
        cpuCoresInfo.frame = NSRect(x: subIndent, y: y + 3, width: 110, height: 13)
        cpuLoadInfo.alignment = .right
        cpuLoadInfo.frame = NSRect(x: subIndent + 110,
                                   y: y + 3, width: PageUI.pageWidth - PageUI.cardPadding - subIndent - 110, height: 13)
        card.addSubview(cpuCoresInfo)
        card.addSubview(cpuLoadInfo)
        y += 19
        PageUI.separator(in: card, y: y)
        y += 8

        y = addMetricRow("GPU", spark: gpuSpark, sparkHeight: 24, value: gpuValue,
                         y: y, rowHeight: 24, in: card)
        y += 7
        PageUI.separator(in: card, y: y)
        y += 8

        y = addMetricRow("RAM", spark: ramSpark, sparkHeight: 24, value: ramValue,
                         y: y, rowHeight: 24, in: card)
        ramInfo.alignment = .right
        ramInfo.frame = NSRect(x: subIndent, y: y + 3,
                               width: PageUI.pageWidth - PageUI.cardPadding - subIndent, height: 13)
        card.addSubview(ramInfo)
        y += 19 + 7

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("占用率", in: card, slot: .usage)
        return top + y
    }

    private func buildTempCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
        let card = CardView()
        cpuTempSpark.scaleFormat = .celsius
        gpuTempSpark.scaleFormat = .celsius

        y = addMetricRow("CPU", spark: cpuTempSpark, sparkHeight: 20, value: cpuTempValue,
                         y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7
        y = addMetricRow("GPU", spark: gpuTempSpark, sparkHeight: 20, value: gpuTempValue,
                         y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7

        // 峰值已画进 sparkline，底部展示四类可独立读取的辅助温度
        let cellWidth = PageUI.innerWidth / 4
        let cells = [("磁盘", diskTempValue), ("电池平均", batteryTempValue),
                     ("内存", memoryTempValue), ("SoC 平均", socTempValue)]
        for (index, (title, value)) in cells.enumerated() {
            let x = PageUI.cardPadding + cellWidth * CGFloat(index)
            let caption = PageUI.label(title, size: 9.5, color: .tertiaryLabelColor)
            caption.alignment = .right
            caption.frame = NSRect(x: x, y: y, width: cellWidth, height: 12)
            value.alignment = .right
            value.frame = NSRect(x: x, y: y + 13, width: cellWidth, height: 15)
            card.addSubview(caption)
            card.addSubview(value)
        }
        y += 31 + 8

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("温度", in: card, slot: .temperature)
        return top + y
    }

    private func buildDiskCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
        let card = CardView()
        readSpark.scaleFormat = .rate
        writeSpark.scaleFormat = .rate

        y = addMetricRow("读取", spark: readSpark, sparkHeight: 20, value: readValue,
                         y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7
        y = addMetricRow("写入", spark: writeSpark, sparkHeight: 20, value: writeValue,
                         y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7

        readTotalLabel.alignment = .right
        readTotalLabel.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth / 2, height: 13)
        writeTotalLabel.alignment = .right
        writeTotalLabel.frame = NSRect(x: PageUI.cardPadding + PageUI.innerWidth / 2, y: y,
                                       width: PageUI.innerWidth / 2, height: 13)
        card.addSubview(readTotalLabel)
        card.addSubview(writeTotalLabel)
        y += 13 + 8

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("磁盘", in: card, slot: .disk)
        return top + y
    }

    private func buildNetworkCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
        let card = CardView()
        netSpark.scaleFormat = .rate

        let columnWidth = PageUI.innerWidth / 2
        for (index, (title, value)) in [("下载", downValue), ("上传", upValue)].enumerated() {
            let x = PageUI.cardPadding + columnWidth * CGFloat(index)
            let caption = PageUI.label(title, size: 10.5, color: .tertiaryLabelColor)
            caption.frame = NSRect(x: x, y: y, width: columnWidth - 4, height: 13)
            value.frame = NSRect(x: x, y: y + 14, width: columnWidth - 4, height: 24)
            card.addSubview(caption)
            card.addSubview(value)
        }
        y += 14 + 24 + 8

        netSpark.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth, height: 30)
        card.addSubview(netSpark)
        y += 30 + 8
        PageUI.separator(in: card, y: y)
        y += 7

        for (title, value) in [("出口接口", interfaceValue), ("内网 IP", localIPValue), ("公网 IP", publicIPValue)] {
            let name = PageUI.label(title, size: 12, color: .secondaryLabelColor)
            name.frame = NSRect(x: PageUI.cardPadding, y: y, width: 110, height: 16)
            value.alignment = .right
            value.frame = NSRect(x: PageUI.cardPadding + 110, y: y,
                                 width: PageUI.innerWidth - 110, height: 16)
            card.addSubview(name)
            card.addSubview(value)
            y += 21
        }
        y += 3

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("网络", in: card, slot: .network)
        return top + y
    }

    // MARK: 刷新

    func update(_ history: [StatsSample]) {
        self.history = history
        guard let last = history.last else { return }
        updateUsageCard(last)
        updateTempCard(last)
        updateDiskCard(last)
        updateNetworkCard(last)
    }

    /// 按某张卡自己的档位降采样；取值时带上采样序号，分桶才能锚定绝对时间而非窗口位置
    private func mean(_ slot: SparklineRange.Slot, _ metric: (StatsSample) -> Double) -> [Double] {
        SparklineDownsample.average(history.map { (index: $0.sequence, value: metric($0)) },
                                    range: range(slot))
    }

    private func updateUsageCard(_ last: StatsSample) {
        cpuSpark.update([.init(values: mean(.usage, \.cpuUsage), color: StatsPalette.cpu)])
        gpuSpark.update([.init(values: mean(.usage, \.gpuUsage), color: StatsPalette.gpu)])
        ramSpark.update([.init(values: mean(.usage, \.ramUsage), color: StatsPalette.ram)])
        cpuValue.stringValue = StatsFormat.percent(last.cpuUsage)
        gpuValue.stringValue = StatsFormat.percent(last.gpuUsage)
        ramValue.stringValue = StatsFormat.percent(last.ramUsage)

        if let e = last.cpuECore, let p = last.cpuPCore {
            cpuCoresInfo.stringValue = "E 核 \(StatsFormat.percent(e))  P 核 \(StatsFormat.percent(p))"
        } else {
            cpuCoresInfo.stringValue = ""
        }
        cpuLoadInfo.stringValue = last.loadAvg.count == 3
            ? String(format: "负载 %.2f / %.2f / %.2f", last.loadAvg[0], last.loadAvg[1], last.loadAvg[2])
            : ""
        ramInfo.stringValue = "App \(StatsFormat.gigabytes(last.ramApp)) GB · 联动 \(StatsFormat.gigabytes(last.ramWired)) GB · SWAP \(StatsFormat.gigabytes(last.swapUsed)) GB"
    }

    /// 两条温度线同属温度卡，共用该卡档位
    private func updateTempCard(_ last: StatsSample) {
        let range = range(.temperature)
        updateTempSpark(cpuTempSpark, samples: history.compactMap { sample in
            sample.cpuTemp.map { (index: sample.sequence, mean: $0, peak: sample.cpuTempMax ?? $0) }
        }, range: range, meanColor: StatsPalette.cpuSoft, peakColor: StatsPalette.cpuFaint)
        updateTempSpark(gpuTempSpark, samples: history.compactMap { sample in
            sample.gpuTemp.map { (index: sample.sequence, mean: $0, peak: sample.gpuTempMax ?? $0) }
        }, range: range, meanColor: StatsPalette.gpuSoft, peakColor: StatsPalette.gpuFaint)
        applyTemp(cpuTempValue, last.cpuTemp)
        applyTemp(gpuTempValue, last.gpuTemp)
        applyTemp(diskTempValue, last.diskTemp)
        applyTemp(batteryTempValue, last.batteryTemp)
        applyTemp(memoryTempValue, last.memoryTemp)
        applyTemp(socTempValue, last.socTemp)
    }

    private func updateDiskCard(_ last: StatsSample) {
        readSpark.update([.init(values: mean(.disk, \.diskRead),
                                color: StatsPalette.neutralPrimary, lineWidth: 1.4)])
        writeSpark.update([.init(values: mean(.disk, \.diskWrite),
                                 color: StatsPalette.neutralSecondary, lineWidth: 1.4)])
        readValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskRead), unit: "MB/s",
                                                               numberSize: PageUI.rowValueSize, unitSize: 10)
        writeValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskWrite), unit: "MB/s",
                                                                numberSize: PageUI.rowValueSize, unitSize: 10)
        readTotalLabel.stringValue = "累计读取 \(StatsFormat.dataVolume(last.diskReadTotal))"
        writeTotalLabel.stringValue = "累计写入 \(StatsFormat.dataVolume(last.diskWriteTotal))"
    }

    private func updateNetworkCard(_ last: StatsSample) {
        netSpark.update([
            .init(values: mean(.network, \.netDown), color: StatsPalette.neutralPrimary, lineWidth: 1.4),
            .init(values: mean(.network, \.netUp), color: StatsPalette.neutralSecondary, lineWidth: 1.2),
        ])
        downValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netDown), unit: "MB/s",
                                                               numberSize: 19, unitSize: 11)
        upValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netUp), unit: "MB/s",
                                                             numberSize: 19, unitSize: 11,
                                                             color: .secondaryLabelColor)
    }

    /// 温度 sparkline：均值线（桶内平均）+ 峰值线（桶内最高核心温度，更细更弱）。
    /// 峰均差全部小于均值窗口平均值的 `peakVisibilityRatio` 时省略峰值线（DESIGN.md「弹窗」）。
    private func updateTempSpark(_ spark: SparklineView, samples: [(index: Int, mean: Double, peak: Double)],
                                 range: SparklineRange, meanColor: NSColor, peakColor: NSColor) {
        // 两条线共用同一套采样序号，桶边界完全对齐
        let means = SparklineDownsample.average(samples.map { (index: $0.index, value: $0.mean) }, range: range)
        guard !means.isEmpty else {
            spark.update([])
            return
        }
        // 峰值线排在均值线之前，绘制时被均值线覆盖，保持弱线在下
        var series: [SparklineView.Series] = []
        let peaks = SparklineDownsample.maximum(samples.map { (index: $0.index, value: $0.peak) }, range: range)
        let average = means.reduce(0, +) / Double(means.count)
        let spread = zip(peaks, means).map { $0 - $1 }.max() ?? 0
        if spread >= average * Self.peakVisibilityRatio {
            series.append(.init(values: peaks, color: peakColor, lineWidth: 1))
        }
        series.append(.init(values: means, color: meanColor))
        spark.update(series)
    }

    /// 温度数值按分级着色（DESIGN.md 温度分级）；常温与无数据用默认标签色
    private func applyTemp(_ label: NSTextField, _ temp: Double?) {
        label.stringValue = tempText(temp)
        label.textColor = TempTier(temp)?.text ?? .labelColor
    }

    private func tempText(_ temp: Double?) -> String {
        temp.map { String(format: "%.0f°", $0) } ?? "—"
    }

    /// 页面展示时刷新路由信息与公网 IP（公网 IP 有缓存）
    func onShow() {
        if let route = RouteInfo.current() {
            interfaceValue.stringValue = route.displayName.map { "\(route.bsdName) · \($0)" } ?? route.bsdName
            localIPValue.stringValue = route.localIP ?? "—"
        } else {
            interfaceValue.stringValue = "无网络"
            localIPValue.stringValue = "—"
        }
        applyPublicIP()
        publicIP.refreshIfStale { [weak self] in self?.applyPublicIP() }
    }

    private func applyPublicIP() {
        publicIPValue.stringValue = publicIP.current?.ip ?? "获取中…"
    }
}
