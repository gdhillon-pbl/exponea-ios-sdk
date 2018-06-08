//
//  TrackingManager.swift
//  ExponeaSDK
//
//  Created by Dominik Hádl on 11/04/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation

/// The Tracking Manager class is responsible to manage the automatic tracking events when
/// it's enable and persist the data according to each event type.
open class TrackingManager {
    let database: DatabaseManagerType
    let repository: RepositoryType
    let device: DeviceProperties
    
    /// The identifiers of the the current customer.
    var customerIds: [String: String] {
        return database.customer.ids
    }
    
    /// Payment manager responsible to track all in app payments.
    internal var paymentManager: PaymentManagerType {
        didSet {
            paymentManager.delegate = self
            paymentManager.startObservingPayments()
        }
    }
    
    /// The manager for automatic push registration and delivery tracking
    internal var pushManager: PushNotificationManager?
    
    /// Used for periodic data flushing.
    internal var flushingTimer: Timer?
    
    /// Flushing mode specifies how often and if should data be automatically flushed to Exponea.
    /// See `FlushingMode` for available values.
    public var flushingMode: FlushingMode = .automatic {
        didSet {
            Exponea.logger.log(.verbose, message: "Flushing mode updated to: \(flushingMode).")
            updateFlushingMode()
        }
    }
    
    init(repository: RepositoryType,
         database: DatabaseManagerType = DatabaseManager(),
         device: DeviceProperties = DeviceProperties(),
         paymentManager: PaymentManagerType = PaymentManager()) {
        self.repository = repository
        self.database = database
        self.device = device
        self.paymentManager = paymentManager
        
        initialSetup()
    }
    
    deinit {
        removeSessionObservers()
        Exponea.logger.log(.verbose, message: "TrackingManager deallocated.")
    }
    
    func initialSetup() {
        /// Add the observers when the automatic session tracking is true.
        if repository.configuration.automaticSessionTracking {
            addSessionObserves()
        }
        
        /// Add the observers when the automatic push notification tracking is true.
        if repository.configuration.automaticPushNotificationTracking {
            pushManager = PushNotificationManager(trackingManager: self)
        }
    }
}

extension TrackingManager: TrackingManagerType {
    open func track(_ type: EventType, with data: [DataType]?) throws {
        /// Get token mapping or fail if no token provided.
        let tokens = repository.configuration.tokens(for: type)
        if tokens.isEmpty {
            throw TrackingManagerError.unknownError("No project tokens provided.")
        }
        
        Exponea.logger.log(.verbose, message: "Tracking event of type: \(type).")
        
        /// For each project token we have, track the data.
        for projectToken in tokens {
            let payload: [DataType] = [.projectToken(projectToken)] + (data ?? [])
            
            switch type {
            case .install: try trackInstall(projectToken: projectToken)
            case .sessionStart: try trackStartSession(projectToken: projectToken)
            case .sessionEnd: try trackEndSession(projectToken: projectToken)
            case .customEvent: try trackEvent(with: payload)
            case .identifyCustomer: try identifyCustomer(with: payload)
            case .payment: try trackPayment(with: payload)
            case .registerPushToken: try trackPushToken(with: payload)
            case .pushOpened: try trackPushOpened(with: payload)
            case .pushDelivered: try trackPushDelivered(with: payload)
            }
        }
    }
}

extension TrackingManager {
    open func trackInstall(projectToken: String) throws {
        try database.trackEvent(with: [.projectToken(projectToken),
                                       .properties(device.properties),
                                       .eventType(Constants.EventTypes.installation)])
    }
    
    open func trackEvent(with data: [DataType]) throws {
        try database.trackEvent(with: data)
    }
    
    open func identifyCustomer(with data: [DataType]) throws {
        try database.trackCustomer(with: data)
    }
    
    open func trackPayment(with data: [DataType]) throws {
        try database.trackEvent(with: data + [.eventType(Constants.EventTypes.payment)])
    }
    
    open func trackPushToken(with data: [DataType]) throws {
        try database.trackCustomer(with: data)
    }
    
    open func trackPushOpened(with data: [DataType]) throws {
        try database.trackEvent(with: data + [.eventType(Constants.EventTypes.pushOpen)])
    }
    
    open func trackPushDelivered(with data: [DataType]) throws {
        try database.trackEvent(with: data + [.eventType(Constants.EventTypes.pushDelivered)])
    }
}

// MARK: - Sessions

extension TrackingManager {
    internal var sessionStartTime: Double {
        get {
            return Exponea.shared.userDefaults.double(forKey: Constants.Keys.sessionStarted)
        }
        set {
            Exponea.shared.userDefaults.set(newValue, forKey: Constants.Keys.sessionStarted)
        }
    }
    
    internal var sessionEndTime: Double {
        get {
            return Exponea.shared.userDefaults.double(forKey: Constants.Keys.sessionEnded)
        }
        set {
            Exponea.shared.userDefaults.set(newValue, forKey: Constants.Keys.sessionEnded)
        }
    }
    
    /// Add observers to notification center in order to control when the
    /// app become active or enter in background.
    internal func addSessionObserves() {
        // Make sure we remove session observers first, if we are already observing.
        removeSessionObservers()
        
        // Subscribe to notifications
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillTerminate),
                                               name: UIApplication.willTerminateNotification,
                                               object: nil)
        
        try? track(.sessionStart, with: nil)
    }
    
    /// Removes session observers.
    internal func removeSessionObservers() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willTerminateNotification, object: nil)
    }
    
    @objc internal func applicationDidBecomeActive() {
        // If this is first session start, then
        guard sessionStartTime != 0 else {
            sessionStartTime = Date().timeIntervalSince1970
            return
        }
        
        // Check first if we're past session timeout. If yes, track end of a session.
        if shouldTrackCurrentSession {
            do {
                // Track session end
                try track(.sessionEnd, with: nil)
                
                // Reset session
                sessionStartTime = Date().timeIntervalSince1970
                sessionEndTime = 0
                
                Exponea.logger.log(.verbose, message: Constants.SuccessMessages.sessionStart)
            } catch {
                Exponea.logger.log(.error, message: error.localizedDescription)
            }
        } else {
            Exponea.logger.log(.verbose, message: "Skipping tracking session end as within timeout or not started.")
        }
    }
    
    @objc internal func applicationDidEnterBackground() {
        // Set the session end to the time when the app resigns active state
        sessionEndTime = Date().timeIntervalSince1970
    }
    
    @objc internal func applicationWillTerminate() {
        // Set the session end to the time when the app terminates
        sessionEndTime = Date().timeIntervalSince1970
        
        // Track session end (when terminating)
        do {
            try track(.sessionEnd, with: nil)
            
            // Reset session times
            sessionStartTime = 0
            sessionEndTime = 0
            
            Exponea.logger.log(.verbose, message: Constants.SuccessMessages.sessionEnd)
        } catch {
            Exponea.logger.log(.error, message: error.localizedDescription)
        }
    }
    
    fileprivate var shouldTrackCurrentSession: Bool {
        /// Make sure a session was started
        guard sessionStartTime > 0 else {
            Exponea.logger.log(.warning, message: """
            Session not started - you need to first start a session before ending it.
            """)
            return false
        }
        
        // If current session didn't end yet, then we shouldn't track it
        guard sessionEndTime > 0 else {
            return false
        }
        
        /// Calculate the session duration
        let sessionDuration = sessionEndTime - sessionStartTime
        
        /// Session should be ended
        if sessionDuration > repository.configuration.sessionTimeout {
            return true
        } else {
            return false
        }
    }
    
    internal func trackStartSession(projectToken: String) throws {
        /// Prepare data to persist into coredata.
        var properties = device.properties
        
        /// Adding session start properties.
        properties["event_type"] = .string(Constants.EventTypes.sessionStart)
        properties["timestamp"] = .double(sessionStartTime)
        
        try database.trackEvent(with: [.projectToken(projectToken),
                                       .properties(properties),
                                       .eventType(Constants.EventTypes.sessionStart)])
    }
    
    internal func trackEndSession(projectToken: String) throws {
        /// Prepare data to persist into coredata.
        var properties = device.properties
        
        /// Calculate the duration of the last session.
        let duration = sessionEndTime - sessionStartTime
        
        /// Adding session end properties.
        properties["event_type"] = .string(Constants.EventTypes.sessionEnd)
        properties["timestamp"] = .double(sessionStartTime)
        properties["duration"] = .double(duration)
        
        try database.trackEvent(with: [.projectToken(projectToken),
                                       .properties(properties),
                                       .eventType(Constants.EventTypes.sessionEnd)])
    }
}

// MARK: - Flushing -

extension TrackingManager {
    @objc func flushData() {
        do {
            // Pull from db
            let events = try database.fetchTrackEvent().reversed()
            let customers = try database.fetchTrackCustomer().reversed()
            
            Exponea.logger.log(.verbose, message: """
                Flushing data: \(events.count + customers.count) total objects to upload, \
                \(events.count) events and \(customers.count) customer updates.
                """)
            
            // Check if we have any data, otherwise bail
            guard !events.isEmpty || !customers.isEmpty else {
                return
            }
            
            flushCustomerTracking(Array(customers))
            flushEventTracking(Array(events))
        } catch {
            Exponea.logger.log(.error, message: error.localizedDescription)
        }
    }
    
    func flushCustomerTracking(_ customers: [TrackCustomer]) {
        for customer in customers {
            repository.trackCustomer(with: customer.dataTypes, for: customerIds) { [weak self] (result) in
                switch result {
                case .success:
                    Exponea.logger.log(.verbose, message: """
                        Successfully uploaded customer update: \(customer.objectID).
                        """)
                    do {
                        try self?.database.delete(customer)
                    } catch {
                        Exponea.logger.log(.error, message: """
                            Failed to remove object from database: \(customer.objectID).
                            \(error.localizedDescription)
                            """)
                    }
                case .failure(let error):
                    Exponea.logger.log(.error, message: """
                        Failed to upload customer update. \(error.localizedDescription)
                        """)
                }
            }
        }
    }
    
    func flushEventTracking(_ events: [TrackEvent]) {
        for event in events {
            repository.trackEvent(with: event.dataTypes, for: customerIds) { [weak self] (result) in
                switch result {
                case .success:
                    Exponea.logger.log(.verbose, message: "Successfully uploaded event: \(event.objectID).")
                    do {
                        try self?.database.delete(event)
                    } catch {
                        Exponea.logger.log(.error, message: """
                            Failed to remove object from database: \(event.objectID). \(error.localizedDescription)
                            """)
                    }
                case .failure(let error):
                    Exponea.logger.log(.error, message: "Failed to upload event. \(error.localizedDescription)")
                }
            }
        }
    }
    
    func updateFlushingMode() {
        // Invalidate timers
        flushingTimer?.invalidate()
        flushingTimer = nil
        
        // Remove observers
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        
        // Update for new flushing mode
        switch flushingMode {
        case .manual: break
        case .automatic:
            // Automatically upload on resign active
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(flushData),
                               name: UIApplication.willResignActiveNotification, object: nil)
            
        case .periodic(let interval):
            // Schedule a timer for the specified interval
            flushingTimer = Timer(timeInterval: TimeInterval(interval), target: self,
                                  selector: #selector(flushData), userInfo: nil, repeats: true)
        }
    }
}

// MARK: - Payments -

extension TrackingManager: PaymentManagerDelegate {
    public func trackPaymentEvent(with data: [DataType]) {
        do {
            try track(.payment, with: data)
            Exponea.logger.log(.verbose, message: Constants.SuccessMessages.paymentDone)
        } catch {
            Exponea.logger.log(.error, message: error.localizedDescription)
        }
    }
}