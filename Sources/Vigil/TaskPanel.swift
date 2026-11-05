import SwiftUI
import UniformTypeIdentifiers
import VigilCore
import VigilVoice

/// Drag payload prefix for to-dos dropped onto the week grid.
enum TodoDrag {
    static let prefix = "vigil-todo:"
}

/// Unscheduled tasks beside the week grid. Type or speak a task; Vigil shows what it understood
/// before adding it. Drag a task onto the grid (or press "Next slot") to block time for it.
struct TaskPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var speech = SpeechCapture()
    @State private var draft = ""
    @State private var plan: VoicePlan?

    var body: some View {
        Card {
            HStack {
                SectionHeader(number: "T", title: "Tasks", note: "\(model.todos.count) open")
            }
            capture
            if let plan { PlanPreview(plan: Binding(get: { plan }, set: { self.plan = $0 }), onAdd: add, onCancel: { self.plan = nil }) }
            if model.todos.isEmpty && plan == nil {
                Text("Nothing waiting. Say something like “Essay draft tomorrow 2 to 4pm, block distractions” or “Revise statistics for an hour”.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.todos) { t in row(t) }
        }
        .onChange(of: speech.listening) { listening in
            if !listening, !speech.transcript.isEmpty { draft = speech.transcript; understand() }
        }
        .onChange(of: speech.transcript) { text in if speech.listening { draft = text } }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(speech.listening ? "Listening…" : "Add a task, or press the mic", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(understand)
                Button { Task { await speech.toggle() } } label: {
                    Image(systemName: speech.listening ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(speech.listening ? Theme.accent : Theme.ink)
                        .frame(width: 22)
                }
                .buttonStyle(.borderless)
                .help(speech.listening ? "Stop listening" : "Speak a task (on-device only)")
            }
            if speech.listening {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("LISTENING · ON-DEVICE").font(Theme.label(9)).foregroundStyle(Theme.accent)
                }
            }
            if let problem = speech.problem { Text(problem).font(.caption).foregroundStyle(Theme.distracting) }
        }
    }

    private func understand() {
        plan = VoicePlanner.parse(draft)
        if plan == nil, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            model.lastMessage = "Couldn't find a task in that. Try “Gym tomorrow at 7”."
        }
    }

    private func add(_ p: VoicePlan) {
        model.addPlanned(p.item())
        plan = nil
        draft = ""
    }

    private func row(_ t: TimetableItem) -> some View {
        HStack(spacing: 8) {
            Button { model.completeTodo(t) } label: { Image(systemName: "circle").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 12.5)).lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(t.estimate ?? 60) MIN").font(Theme.label(8.5)).foregroundStyle(.secondary)
                    if t.wantsFocus == true {
                        Label("FOCUS", systemImage: "hand.raised.fill").font(Theme.label(8.5)).foregroundStyle(Theme.accent)
                    }
                }
            }
            Spacer(minLength: 4)
            Button("Next slot") {
                model.schedule(t, at: model.nextFreeSlot(minutes: t.estimate ?? 60))
            }
            .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .help("Put it in the next free slot today or tomorrow")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: (TodoDrag.prefix + t.id) as NSString) }
        .help("Drag onto the week to block time for it")
    }
}

/// What Vigil understood from the sentence, editable before it's added.
struct PlanPreview: View {
    @Binding var plan: VoicePlan
    var onAdd: (VoicePlan) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UNDERSTOOD").font(Theme.label(9)).foregroundStyle(Theme.accent)
            TextField("Title", text: $plan.title).textFieldStyle(.roundedBorder)
            if let start = plan.start {
                let end = plan.end ?? start.addingTimeInterval(Double(plan.minutes ?? 60) * 60)
                Text("\(start.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
            } else {
                Stepper("Takes about \(plan.minutes ?? 60) min", value: Binding(get: { plan.minutes ?? 60 }, set: { plan.minutes = $0 }),
                        in: 15...480, step: 15)
                    .font(.callout)
                Text("No time heard: it goes to your tasks.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Block distractions during it", isOn: $plan.focus).font(.callout)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(plan.start == nil ? "Add task" : "Add to timetable") { onAdd(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
