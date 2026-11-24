import SwiftUI
import UIKit

@main
final class App: UIResponder, UIApplicationDelegate {
  func application(
    _ app: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 16.1, *) { TerminalIsland.clearPreviousLaunch() }
    #if DEBUG
      // Development pairing exports only the public key; the private seed stays in Keychain.
      do {
        let documents = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try Identity.publicLine().write(
          to: documents.appendingPathComponent("tmux-link-public-key.pub"),
          atomically: true, encoding: .utf8)
      } catch {
        NSLog("Development public-key export failed: %@", error.localizedDescription)
      }
    #endif
    return true
  }

  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Terminal", sessionRole: session.role)
    configuration.delegateClass = Scene.self
    return configuration
  }
}

final class Scene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private let activity = WorkspaceActivity()
  private let enrollment = EnrollmentStatus()
  private let clientLinks = ClientImportLinks()

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    for context in contexts { clientLinks.open(context.url) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) { activity.isActive = true }
  func sceneWillResignActive(_ scene: UIScene) { activity.isActive = false }

  func sceneWillEnterForeground(_ scene: UIScene) {
    do {
      try RelayIdentity.processEnrollment()
      enrollment.error = nil
    } catch {
      enrollment.error = "设备证书注册失败：" + error.localizedDescription
    }
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    for context in connectionOptions.urlContexts { clientLinks.open(context.url) }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UIHostingController(
      rootView: Workspace(enrollment: enrollment, clientLinks: clientLinks, activity: activity))
    window.makeKeyAndVisible()
    self.window = window
  }
}
