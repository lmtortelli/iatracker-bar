import AppKit
import IAtrackerBarCore
import SwiftUI

/// Linha da lista de sessões do dia.
struct SessionRow: View {
    let session: Session
    let projectName: String
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: session.provider, size: 22, radius: 6, fontSize: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.source)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(projectName) · \(range)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Formatters.duration(session.duration(now: now)))
                .font(Theme.mono(12, .medium))
                .foregroundColor(.primary.opacity(0.8))
        }
        .padding(.vertical, 7)
        .topSeparator()
    }

    private var range: String {
        let start = Formatters.time(session.startedAt)
        guard let end = session.endedAt else { return "\(start) – agora" }
        return "\(start)–\(Formatters.time(end))"
    }
}

/// Botão `Projeto: Nome ▾` com o visual do protótipo. Usa `NSMenu` porque o `Menu`
/// do SwiftUI ignora borda e fundo customizados na barra de menus.
struct ProjectMenuButton: View {
    let projectName: String
    let projects: [Project]
    let onSelect: (Project) -> Void
    let onCreate: (String) -> Void

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: 4) {
                Text("Projeto:")
                Text(projectName).fontWeight(.semibold)
                Text("▾")
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Projeto: \(projectName). Alterar projeto")
    }

    @MainActor
    private func showMenu() {
        let menu = NSMenu()
        for project in projects {
            let item = ClosureMenuItem(title: project.name) { onSelect(project) }
            item.state = project.name == projectName ? .on : .off
            menu.addItem(item)
        }
        if !projects.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Novo projeto…") { askNewProject() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @MainActor
    private func askNewProject() {
        if let name = TextPrompt.ask(
            title: "Novo projeto",
            message: "A sessão atual passa a contar para este projeto.",
            confirm: "Criar"
        ) {
            onCreate(name)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) não suportado")
    }

    @objc private func fire() {
        handler()
    }
}
