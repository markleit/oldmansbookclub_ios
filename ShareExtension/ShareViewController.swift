import UIKit
import SwiftUI

// #178 — the extension's principal class (NSExtensionPrincipalClass). Hosts the SwiftUI sheet
// and owns the extension context: completeRequest on success, cancelRequest on Cancel.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { [weak self] in
            guard let self else { return }
            await model.start(context: extensionContext) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}
