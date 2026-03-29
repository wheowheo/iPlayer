import AppKit

final class ClothingManagerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let db = ClothingDatabase.shared
    private var items: [ClothingItem] = []
    private let statsLabel = NSTextField(labelWithString: "")
    private var typeFilter: ClothingType? = nil

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "옷장 관리"
        window.center()
        window.minSize = NSSize(width: 450, height: 300)
        self.init(window: window)
        setupUI()
        reload()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // 상단: 통계 + 필터
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .secondaryLabelColor
        topBar.addArrangedSubview(statsLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(spacer)

        // 타입 필터
        let filterPopup = NSPopUpButton()
        filterPopup.addItem(withTitle: "전체")
        for type in ClothingType.allCases { filterPopup.addItem(withTitle: type.rawValue) }
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged(_:))
        topBar.addArrangedSubview(filterPopup)

        // 추가/삭제 버튼
        let addBtn = NSButton(title: "+", target: self, action: #selector(addItem))
        addBtn.bezelStyle = .inline
        let delBtn = NSButton(title: "−", target: self, action: #selector(deleteSelected))
        delBtn.bezelStyle = .inline
        topBar.addArrangedSubview(addBtn)
        topBar.addArrangedSubview(delBtn)

        contentView.addSubview(topBar)

        // 테이블
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false

        let cols: [(String, String, CGFloat)] = [
            ("active", "착용", 36),
            ("color", "색상", 36),
            ("name", "이름", 150),
            ("type", "종류", 60),
            ("pattern", "패턴", 60),
            ("opacity", "투명도", 55),
            ("notes", "메모", 140),
        ]
        for (id, title, width) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 30
            if id == "name" || id == "notes" {
                col.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(col)
        }

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            topBar.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func reload() {
        if let filter = typeFilter {
            items = db.fetchByType(filter)
        } else {
            items = db.fetchAll()
        }
        tableView.reloadData()
        updateStats()
    }

    private func updateStats() {
        let s = db.stats()
        let types = s.byType.map { "\($0.0.rawValue) \($0.1)" }.joined(separator: " · ")
        statsLabel.stringValue = "총 \(s.total)벌 | 착용 \(s.active)벌 | \(types)"
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            typeFilter = nil
        } else {
            typeFilter = ClothingType.allCases[sender.indexOfSelectedItem - 1]
        }
        reload()
    }

    @objc private func addItem() {
        let id = db.insert(name: "새 옷", type: .top)
        if id > 0 { reload() }
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        db.delete(id: items[row].id)
        reload()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let id = col.identifier.rawValue

        switch id {
        case "active":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleActive(_:)))
            check.state = item.isActive ? .on : .off
            check.tag = row
            return check

        case "color":
            let view = NSView()
            view.wantsLayer = true
            let c = item.color
            view.layer?.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1).cgColor
            view.layer?.cornerRadius = 4
            return view

        case "name":
            let field = editableField(item.name, row: row, col: id)
            return field

        case "type":
            let label = NSTextField(labelWithString: item.type.rawValue)
            label.font = .systemFont(ofSize: 11)
            return label

        case "pattern":
            let label = NSTextField(labelWithString: item.pattern)
            label.font = .systemFont(ofSize: 11)
            return label

        case "opacity":
            let label = NSTextField(labelWithString: String(format: "%.0f%%", item.opacity * 100))
            label.font = .systemFont(ofSize: 11)
            return label

        case "notes":
            let field = editableField(item.notes, row: row, col: id)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            return field

        default:
            return nil
        }
    }

    private func editableField(_ text: String, row: Int, col: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = true
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 12)
        field.tag = row
        field.identifier = NSUserInterfaceItemIdentifier(col)
        field.target = self
        field.action = #selector(cellEdited(_:))
        return field
    }

    @objc private func toggleActive(_ sender: NSButton) {
        let row = sender.tag
        guard row < items.count else { return }
        db.toggleActive(id: items[row].id)
        reload()
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let row = sender.tag
        guard row < items.count else { return }
        var item = items[row]
        switch sender.identifier?.rawValue {
        case "name": item.name = sender.stringValue
        case "notes": item.notes = sender.stringValue
        default: break
        }
        db.update(item)
        reload()
    }
}
