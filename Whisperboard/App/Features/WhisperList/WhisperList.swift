//
// WhisperList.swift
//

import AVFoundation
import ComposableArchitecture
import SwiftUI

// MARK: - WhisperList

struct WhisperList: ReducerProtocol {
  struct State: Equatable {
    var alert: AlertState<Action>?
    var audioRecorderPermission = RecorderPermission.undetermined
    var recording: Recording.State?
    var whispers: IdentifiedArrayOf<Whisper.State> = []
    var isTranscribing = false
    var transcribingIdInProgress: Whisper.State.ID?
    var expandedWhisperId: Whisper.State.ID?
    var settings = Settings.State()
    @BindableState var isSettingsPresented = false

    enum RecorderPermission {
      case allowed
      case denied
      case undetermined
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case readStoredWhispers
    case setWhispers(TaskResult<IdentifiedArrayOf<Whisper.State>>)
    case alertDismissed
    case openSettingsButtonTapped
    case recordButtonTapped
    case recordPermissionResponse(Bool)
    case recording(Recording.Action)
    case whisper(id: Whisper.State.ID, action: Whisper.Action)
    case gearButtonTapped
    case transcribeWhisper(id: Whisper.State.ID)
    case transcriptionFinished(id: Whisper.State.ID, TaskResult<String>)
    case settings(Settings.Action)
  }

  @Dependency(\.audioRecorder.requestRecordPermission) var requestRecordPermission
  @Dependency(\.date) var date
  @Dependency(\.openSettings) var openSettings
  @Dependency(\.uuid) var uuid
  @Dependency(\.storage) var storage
  @Dependency(\.transcriber) var transcriber

  var body: some ReducerProtocol<State, Action> {
    Scope(state: \.settings, action: /Action.settings) {
      Settings()
    }

    BindingReducer()

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .readStoredWhispers:
        return .task {
          try? await storage.cleanup()
          return await .setWhispers(TaskResult { try await storage.read() })
        }
        .animation()

      case let .setWhispers(result):
        switch result {
        case let .success(value):
          state.whispers = value
        case let .failure(error):
          log(error)
        }
        return .none

      case .alertDismissed:
        state.alert = nil
        return .none

      case .openSettingsButtonTapped:
        return .fireAndForget {
          await self.openSettings()
        }

      case .recordButtonTapped:
        switch state.audioRecorderPermission {
        case .undetermined:
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          return .task {
            await .recordPermissionResponse(self.requestRecordPermission())
          }

        case .denied:
          state.alert = AlertState(
            title: TextState("Permission is required to record voice.")
          )
          return .none

        case .allowed:
          state.recording = newRecording
          return .none
        }

      case let .recording(.delegate(.didFinish(.success(recording)))):
        state.recording = nil
        let whisper = Whisper.State(
          date: recording.date,
          duration: recording.duration,
          fileName: recording.url.lastPathComponent
        )
        state.whispers.insert(whisper, at: 0)
        let id = whisper.id
        return .task { .transcribeWhisper(id: id) }
          .merge(with: .cancel(id: Recording.CancelID()))

      case .recording(.delegate(.didFinish(.failure))):
        state.alert = AlertState(title: TextState("Voice recording failed."))
        state.recording = nil
        return .cancel(id: Recording.CancelID())

      case .recording:
        return .none

      case let .recordPermissionResponse(permission):
        state.audioRecorderPermission = permission ? .allowed : .denied
        if permission {
          state.recording = newRecording
          return .none
        } else {
          state.alert = AlertState(
            title: TextState("Permission is required to record voice.")
          )
          return .none
        }

      case .whisper(id: _, action: .audioPlayerClient(.failure)):
        state.alert = AlertState(title: TextState("Voice playback failed."))
        return .none

      case let .whisper(id: id, action: .delete):
        state.whispers.remove(id: id)
        return .none

      case let .whisper(id: id, action: .retryTranscription):
        return .task { .transcribeWhisper(id: id) }

      case let .whisper(id: tappedId, action: .playButtonTapped):
        for id in state.whispers.ids where id != tappedId {
          state.whispers[id: id]?.mode = .notPlaying
        }
        return .none

      case .gearButtonTapped:
        state.isSettingsPresented = true
        return .none

      case let .transcribeWhisper(id):
        guard !state.isTranscribing,
              let modelURL = state.settings.modelSelector.selectedModel?.type.localURL else { return .none }

        state.isTranscribing = true
        state.transcribingIdInProgress = id
        return .task {
          await .transcriptionFinished(
            id: id,
            TaskResult { try await transcriber.transcribeAudio(storage.fileURLWithName(id), modelURL) }
          )
        }
        .animation()

      case let .whisper(id, .bodyTapped):
        guard !state.isTranscribing else { return .none }

        guard let whisper = state.whispers[id: id] else { return .none }

        if !whisper.isTranscribed {
          return .task { .transcribeWhisper(id: id) }
        } else {
          if state.expandedWhisperId == id {
            state.expandedWhisperId = nil
          } else {
            state.expandedWhisperId = id
          }
          return .none
        }

      case .whisper:
        return .none

      case let .transcriptionFinished(id, result):
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        state.isTranscribing = false
        switch result {
        case let .success(text):
          state.whispers[id: id]?.text = text
          state.whispers[id: id]?.isTranscribed = true
          state.expandedWhisperId = id

        case let .failure(error):
          state.alert = AlertState(title: TextState("Error while transcribing voice recording"), message: TextState(error.localizedDescription))
        }
        return .none

      case .settings:
        return .none
      }
    }
    .ifLet(\.recording, action: /Action.recording) {
      Recording()
    }
    .forEach(\.whispers, action: /Action.whisper(id:action:)) {
      Whisper()
    }
    .onChange(of: \.whispers) { whispers, _, _ -> Effect<Action, Never> in
      .fireAndForget {
        try await storage.write(whispers)
      }
    }
  }

  private var newRecording: Recording.State {
    Recording.State(
      date: date.now,
      url: storage.createNewWhisperURL()
    )
  }
}

// MARK: - WhisperListView

struct WhisperListView: View {
  let store: StoreOf<WhisperList>
  @ObservedObject var viewStore: ViewStoreOf<WhisperList>

  init(store: StoreOf<WhisperList>) {
    self.store = store
    viewStore = ViewStore(store)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        if viewStore.settings.modelSelector.selectedModel == nil {
          Text(viewStore.settings.modelSelector.isLoading
            ? "Loading model..."
            : "No model selected\nPlease select a model in the settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
              ZStack {
                if viewStore.settings.modelSelector.isLoading {
                  Color.Palette.Shadow.primary.ignoresSafeArea()
                  ProgressView().offset(y: 30)
                }
              }
            }
            .font(.DS.titleM)
        } else {
          whisperList()
            .frame(maxHeight: .infinity, alignment: .top)

          recordingControls()
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
      }
      .alert(store.scope(state: \.alert), dismiss: .alertDismissed)
      .navigationTitle("Recordings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button { viewStore.send(.gearButtonTapped) } label: {
            Image(systemName: "gearshape")
              .font(.headline)
          }
        }
      }
      .navigationDestination(isPresented: viewStore.binding(\.$isSettingsPresented)) {
        SettingsView(store: store.scope(state: \.settings, action: WhisperList.Action.settings))
      }
      .background(LinearGradient.screenBackground)
      .accentColor(Color.Palette.Background.accent)
    }
    .task { viewStore.send(.settings(.modelSelector(.task))) }
    .task { await viewStore.send(.readStoredWhispers).finish() }
    .accentColor(Color.Palette.Background.accent)
  }

  func whisperList() -> some View {
    ScrollView {
      LazyVStack(spacing: .grid(8)) {
        ForEachStore(
          store.scope(state: \.whispers, action: { .whisper(id: $0, action: $1) })
        ) { childStore in
          whisperRowView(childStore)
        }
      }
        .padding(.horizontal, .grid(4))
    }
  }

  func recordingControls() -> some View {
    IfLetStore(
      store.scope(state: \.recording, action: { .recording($0) })
    ) { store in
      RecordingView(store: store)
    } else: {
      RecordButton(permission: viewStore.audioRecorderPermission) {
        viewStore.send(.recordButtonTapped, animation: .spring())
      } settingsAction: {
        viewStore.send(.openSettingsButtonTapped)
      }
        .shadow(color: .Palette.Shadow.primary, radius: 20)
    }
    .padding()
    .frame(maxWidth: .infinity)
  }

  func whisperRowView(_ childStore: StoreOf<Whisper>) -> some View {
    let childState = ViewStore(childStore).state
    let isTranscribing = viewStore.isTranscribing && viewStore.transcribingIdInProgress == childState.id
    return WhisperView(store: childStore, isTranscribing: isTranscribing)
  }
}

// MARK: - WhisperListView_Previews

struct WhisperListView_Previews: PreviewProvider {
  static var previews: some View {
    WhisperListView(
      store: Store(
        initialState: WhisperList.State(),
        reducer: WhisperList()
      )
    )
  }
}