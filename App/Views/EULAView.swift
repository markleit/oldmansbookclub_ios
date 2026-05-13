import SwiftUI

struct EULAView: View {
    var onAccepted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Terms of Use")
                .font(.title2.bold())
                .padding(.top, 32)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        termsSection(
                            title: "1. Acceptance",
                            body: "By using Old Man's Book Club you agree to these terms. If you do not agree, do not use the app."
                        )
                        termsSection(
                            title: "2. User-Generated Content",
                            body: "Members may post text messages, voice messages, and images within the club. You are solely responsible for what you post."
                        )
                        termsSection(
                            title: "3. Prohibited Content and Behavior",
                            body: "There is zero tolerance for objectionable content or abusive behavior of any kind. This includes but is not limited to: hate speech, harassment, threats, explicit material, spam, or any content that is illegal or harmful.\n\nViolations will result in immediate removal of the offending content and permanent ejection from the club."
                        )
                        termsSection(
                            title: "4. Reporting and Enforcement",
                            body: "All members have the ability to report messages and block other users. Reports are reviewed by the developer within 24 hours. Reported content will be removed and offending users ejected if a violation is confirmed."
                        )
                        termsSection(
                            title: "5. Privacy",
                            body: "Your use of this app is also governed by our Privacy Policy, available at https://markleit.github.io/oldmansbookclub_ios/privacy.html"
                        )
                        termsSection(
                            title: "6. Changes",
                            body: "These terms may be updated from time to time. Continued use of the app after changes constitutes acceptance of the revised terms."
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Divider()

            Button {
                UserDefaults.standard.set(true, forKey: "hasAcceptedEULA")
                onAccepted()
            } label: {
                Text("I Agree")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func termsSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
