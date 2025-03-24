import SwiftUI
import AVFoundation

@MainActor
class StatusBarController: ObservableObject {
    @Published var isMenuOpen = false
    @Published var isRecording = false
    @Published var lastTranscribedText = ""
    @Published var transcriptionHistory: [String] = []
    @Published var connectionState = "Idle"
    @Published var lastTranscriptionDuration: Double? = nil
    
    // Maximum number of transcriptions to keep in history
    private let maxHistoryItems = 3
    
    // Current session's accumulating transcription text
    private var currentSessionText = ""
    
    // For tracking recording duration
    private var recordingStartTime: Date? = nil
    
    private let keyMonitor = KeyMonitor()
    private let audioRecorder = AudioRecorder()
    private var transcriptionService: TranscriptionService! = nil
    private let textInjector = TextInjector()
    
    // Status icons
    private let idleIcon = "waveform"
    private let recordingIcon = "waveform.circle.fill"
    
    // Feedback sounds
    private let startSound = NSSound(named: "Pop")
    private let endSound = NSSound(named: "Blow")
    
    init() {
        // First create the actor
        transcriptionService = TranscriptionService()
        
        // Then set up everything else
        setupKeyMonitor()
        setupAudioRecorder()
        setupTranscriptionService()
    }
    
    private func setupKeyMonitor() {
        keyMonitor.onRightOptionKeyDown = { [weak self] in
            guard let self = self else { return }
            self.startRecording()
        }
        
        keyMonitor.onRightOptionKeyUp = { [weak self] in
            guard let self = self else { return }
            self.stopRecording()
        }
        
        // Start monitoring keys
        keyMonitor.start()
    }
    
    private func setupAudioRecorder() {
        audioRecorder.onRecordingComplete = { [weak self] audioData in
            guard let self = self else { return }
            // Send the complete audio data for transcription
            Task {
                await self.transcriptionService.finishRecording(withAudioData: audioData)
            }
        }
    }
    
    private func setupTranscriptionService() {
        // Register callbacks through proper API methods
        Task {
            await setupCallbacks()
        }
    }
    
    private func setupCallbacks() async {
        // Create local copies of the callbacks
        let stateChangedCallback: (TranscriptionService.ConnectionState) -> Void = { [weak self] state in
            guard let self = self else { return }
            
            Task { @MainActor in
                switch state {
                case .idle:
                    self.connectionState = "Idle"
                case .recording:
                    self.connectionState = "Recording"
                case .transcribing:
                    self.connectionState = "Transcribing"
                case .error:
                    self.connectionState = "Error"
                }
            }
        }
        
        let receivedCallback: (String) -> Void = { [weak self] text in
            guard let self = self else { return }
            
            Task { @MainActor in
                // Append the new text to the current session's text
                self.currentSessionText += text
                self.lastTranscribedText = self.currentSessionText
                
                // Inject the transcribed text delta to the active application
                self.textInjector.injectText(text)
            }
        }
        
        let completeCallback: () -> Void = { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                // Only add to history if we have some text
                if !self.currentSessionText.isEmpty {
                    // Add current transcription to history
                    self.transcriptionHistory.insert(self.currentSessionText, at: 0)
                    
                    // Limit history size
                    if self.transcriptionHistory.count > self.maxHistoryItems {
                        self.transcriptionHistory.removeLast()
                    }
                }
                
                // Keep the lastTranscribedText for display until next recording starts
                // but reset the session text
                self.currentSessionText = ""
            }
        }
        
        // Set the callbacks on the actor
        await transcriptionService.setCallbacks(
            onStateChanged: stateChangedCallback,
            onReceived: receivedCallback,
            onComplete: completeCallback
        )
    }
    
    func startRecording() {
        guard !isRecording else { return }
        
        isRecording = true
        
        // Reset only the display text for the current session
        currentSessionText = ""
        lastTranscribedText = ""
        
        // Record start time for duration tracking
        recordingStartTime = Date()
        
        // Tell the transcription service we're starting to record
        Task {
            await transcriptionService.startRecording()
        }
        
        // Start audio recording immediately so no audio is missed
        audioRecorder.startRecording()
        
        // Reset text injector
        textInjector.reset()
        
        // Play sound to indicate recording started
        startSound?.play()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        // Calculate recording duration
        if let startTime = recordingStartTime {
            lastTranscriptionDuration = Date().timeIntervalSince(startTime)
        }
        
        // Stop audio recording immediately
        // This will trigger the onRecordingComplete callback which sends the audio data to the transcription service
        audioRecorder.stopRecording()
        isRecording = false
        
        // Note: We don't add to history here anymore - that happens in onTranscriptionComplete
        
        // Play sound to indicate recording stopped
        endSound?.play()
    }
    
    func getStatusIcon() -> String {
        return isRecording ? recordingIcon : idleIcon
    }
    
    deinit {
        // Capture non-isolated properties that don't need MainActor access
        let ts = transcriptionService
        let ar = audioRecorder
        let km = keyMonitor
        
        // Create a fully detached task without any reference to self
        Task.detached {
            // Perform synchronous operations that need MainActor
            await MainActor.run {
                // Clean up key monitor (synchronous operation)
                km.stop()
            }
            
            // Perform async operation separately
            if let transcriptionService = ts {
                await transcriptionService.cancelTranscription()
            }
            
            // Stop recording (requires await since it's actor-isolated)
            await ar.stopRecording()
        }
    }
} 