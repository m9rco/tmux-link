import UIKit

@main
final class App: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(
    _ app: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UINavigationController(rootViewController: Connect())
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

final class Connect: UIViewController {
  let fields = ["公网中心地址", "端口", "Linux 用户名", "内网 SSH 主机指纹 SHA256:…"].map { label in
    let field = UITextField()
    field.placeholder = label
    field.borderStyle = .roundedRect
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.text = UserDefaults.standard.string(forKey: label)
    return field
  }
  let status = UILabel()
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Tmux Link"
    view.backgroundColor = .systemBackground
    if fields[1].text?.isEmpty != false { fields[1].text = "2222" }
    fields[1].keyboardType = .numberPad
    status.numberOfLines = 0
    let copy = UIButton(type: .system)
    copy.setTitle("复制本机 SSH 公钥", for: .normal)
    copy.addTarget(self, action: #selector(copyKey), for: .touchUpInside)
    let go = UIButton(type: .system)
    go.setTitle("连接 tmux", for: .normal)
    go.addTarget(self, action: #selector(connect), for: .touchUpInside)
    let form = UIStackView(arrangedSubviews: fields + [go, copy, status])
    form.axis = .vertical
    form.spacing = 12
    view.addSubview(form)
    form.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      form.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])
  }
  @objc func copyKey() {
    do {
      UIPasteboard.general.string = try Identity.publicLine()
      status.text = "公钥已复制"
    } catch { status.text = error.localizedDescription }
  }
  @objc func connect() {
    let values = fields.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !values[0].isEmpty, let port = UInt16(values[1]), port > 0, !values[2].isEmpty,
      values[3].hasPrefix("SHA256:")
    else {
      status.text = "请输入地址、端口、用户和内网主机指纹"
      return
    }
    do {
      let terminal = try Screen(host: values[0], port: port, user: values[2], pin: values[3])
      for (field, value) in zip(fields, values) {
        UserDefaults.standard.set(value, forKey: field.placeholder!)
      }
      navigationController?.pushViewController(terminal, animated: true)
    } catch { status.text = error.localizedDescription }
  }
}
