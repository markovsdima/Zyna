import UIKit

/// On-screen controls for live glass parameter tuning.
/// Each row: [−] label: value [+]
final class GlassTuningView: UIView {

    private let stack = UIStackView()
    private var rows: [(label: UILabel, valueLabel: UILabel)] = []

    private struct Param {
        let name: String
        let step: Float
        let get: () -> Float
        let set: (Float) -> Void
    }

    private var params: [Param] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 12

        let t = GlassTuning.shared
        params = [
            Param(name: "bevel", step: 2,
                  get: { Float(t.bezelPt) }, set: { t.bezelPt = CGFloat(max($0, 2)) }),
            Param(name: "thick", step: 5,
                  get: { Float(t.glassThickPt) }, set: { t.glassThickPt = CGFloat(max($0, 5)) }),
            Param(name: "IOR", step: 0.5,
                  get: { t.ior }, set: { t.ior = max($0, 1.0) }),
            Param(name: "squN", step: 0.25,
                  get: { t.squircleN }, set: { t.squircleN = max($0, 1.5) }),
            Param(name: "scale", step: 0.1,
                  get: { t.refractScale }, set: { t.refractScale = max($0, 0.1) }),
        ]

        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        for (i, p) in params.enumerated() {
            let row = makeRow(index: i, param: p)
            stack.addArrangedSubview(row)
        }

        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(index: Int, param: Param) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center

        let minus = makeButton("−", tag: index, action: #selector(didTapMinus(_:)))
        let plus = makeButton("+", tag: index, action: #selector(didTapPlus(_:)))

        let label = UILabel()
        label.text = param.name
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let value = UILabel()
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .systemCyan
        value.textAlignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true

        rows.append((label: label, valueLabel: value))

        row.addArrangedSubview(minus)
        row.addArrangedSubview(label)
        row.addArrangedSubview(value)
        row.addArrangedSubview(plus)

        return row
    }

    private func makeButton(_ title: String, tag: Int, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        btn.tintColor = .white
        btn.tag = tag
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return btn
    }

    @objc private func didTapMinus(_ sender: UIButton) {
        let p = params[sender.tag]
        p.set(p.get() - p.step)
        updateLabels()
        GlassService.shared.setNeedsCapture()
    }

    @objc private func didTapPlus(_ sender: UIButton) {
        let p = params[sender.tag]
        p.set(p.get() + p.step)
        updateLabels()
        GlassService.shared.setNeedsCapture()
    }

    private func updateLabels() {
        for (i, p) in params.enumerated() {
            let v = p.get()
            rows[i].valueLabel.text = v == v.rounded() ? String(format: "%.0f", v)
                                                        : String(format: "%.2f", v)
        }
    }
}
