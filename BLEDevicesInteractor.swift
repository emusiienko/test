//
//  BLEDevicesInteractor.swift
//  Mighty
//
//  Created by Evgeniy on 04.06.2018.
//  Copyright © 2018 Mighty Audio. All rights reserved.
//

import Foundation
import CoreBluetooth

class BLEDevicesInteractor: BLEDevicesInteraction, MightyScanServiceDelegate {
  var handleHeadsets: Bool = true
  var saveMightyOperation: ((MightyDescription?) -> ())?
  var initialMighty: MightyDescription?
  var currentUser: MightyLogin!
  var currentMusicCredentialsInfo: MusicServiceAccountParameters?
  var handleState: ((DeviceSearchInteractorState) -> ())?
  var showingAutoconnectAlertEnabled: Bool = true
  var currentState: DeviceSearchInteractorState = .noDeviceFoundYet {
    didSet {
      setUpVarsForCurrentInteractorState()
      handleState?(currentState)
    }
  }

  var needToRenameDeviceWith: ((String, @escaping (String) -> ()) -> ())?
  var connectedMightyDescription: MightyDescription? {
    if connectedMighty != nil {
      return MightyDescription(identifier: connectedMighty!.identifier)
    } else {
      return nil
    }
  }
  var headsetErrorOccured: ((BLEDeviceInteractorHeadsetError) -> ())?

  var scanner: MightyScanProtocol! 
  var peripheralOwner: BLEPeripheralManaging!
  var mightyLoginService: MightyCredentialsSyncServiceProtocol!
  var mightyHeadsetService: MightyHeadsetSetupProtocol!
  var applicationInfo: AppInfo
  
  var tableDelegate: (BLEDevicesDelegateProtocol & BLEHeadsetsDelegateProtocol)! {
    didSet {
      if tableDelegate != nil {
        setupTableDatasource()
        setupTableDelegate()
      }
    }
  }
  var tableDataSource: (BLEDevicesDatasourceProtocol & BLEHeadsetDataSourceProtocol)! {
    didSet {
      if tableDataSource != nil {
        setupTableDatasource()
        setupTableDelegate()
      }
    }
  }
  
  private var mighties: [MightyPeripheral] = [] 
  private var connectingMighty: MightyPeripheral?
  private var connectedMighty: MightyPeripheral?
 
  var isWorking: Bool = false
  
  private var headsets: [BTScanList] = [] {
    didSet {
      tableDelegate.headsets = headsets
      if headsets.map({$0.MacID}) != oldValue.map({$0.MacID}) {
        tableDataSource.headsets = headsets
      }
    }
  }
  private var connectedHeadset: BTScanList? {
    willSet {
      if connectedHeadset != nil {
        tableDataSource.setConnectionState(.notConnected, for: connectedHeadset!)
        tableDataSource.setPairingState(.paired, for: connectedHeadset!)
      }
    }
    didSet {
      if connectedHeadset != nil {
        tableDataSource.setConnectionState(.connected, for: connectedHeadset!)
      }
    }
  }
  
  init(appInfo: AppInfo) {
    applicationInfo = appInfo
  }
  
  func setup() {
    setupHeadsetsService()
  }
  
  func start() {
    setUpLoginService()

    isWorking = true
    if mightyLoginService.isWorking == false {
      mightyLoginService.startWorkWithService()
    }
    let setScanModeClosure: (DeviceSearchInteractorState) -> () = { [unowned self] (state) in
      self.currentState = state
      self.setPeripheralsToTable([])
      self.scan()
    }

    switch mightyLoginService.mightyLoginState {
    case .loggedIn(let compatibility):
      if connectedMighty == nil {
        connectedMighty = mightyLoginService.connectedMightyInfo()!
      }
      self.tableDelegate.showMightyHeader = false
      setPeripheralsToTable([connectedMighty!])
      self.tableDataSource.setState(.deviceConnected, for: connectedMighty!)
      self.setStateToTable(.bluetoothEnabled)
      self.currentState = .mightyAuthentificated(compatibility)
    default:
      if peripheralOwner.currentMightyUUID != nil {
        peripheralOwner.changePeripheral(nil) {
          setScanModeClosure(.noDeviceFoundYet)
        }
      } else {
        if mightyLoginService.BLECommunicationState == .bluetoothEnabled {
          setScanModeClosure(.noDeviceFoundYet)
        } else {
          setScanModeClosure(.noBluetooth(true))
        }
      }
    }
  }

  func cancel() {
    isWorking = false
    self.connectedMighty = nil
    self.connectingMighty = nil
    self.currentState = .noDeviceFoundYet
    mightyLoginService.BLECommunicationEventsHandler = nil
    mightyLoginService.mightyAuthEventsHandler = nil
    mightyLoginService.mightyComunicationEventsHandler = nil
    saveMightyDevice()
    self.mighties = []
    self.headsets = []
    peripheralOwner.changePeripheral(nil, completion: {})
    self.stopScan()
  }

  //MARK: Mighty search
  private func scan() {
    if scanner.bluetoothState == .enabled {
      setStateToTable(.bluetoothEnabled)
    } else {
      setStateToTable(.bluetoothDisabled)
    }
    scanner.scanDelegate = self
    scanner.scan()
  }
  
  private func stopScan() {
    scanner.stopScan()
    scanner.scanDelegate = nil
  }
  
  private func setUpVarsForCurrentInteractorState() {
    switch currentState {
    case .mightyAuthentificated:
      self.connectedMighty = mightyLoginService.connectedMightyInfo()
      self.connectingMighty = nil
      self.tableDelegate.showMightyHeader = true
      self.setPeripheralsToTable([self.connectedMighty!])
      self.tableDataSource.setState(.deviceConnected, for: self.connectedMighty!)
      self.saveMightyDevice()
      self.initialMighty = MightyDescription(identifier: self.connectedMighty!.identifier)
    case .noBluetooth, .noDeviceFoundYet:
      self.connectedMighty = nil
      self.connectingMighty = nil
      self.mighties = []
      self.tableDelegate.showMightyHeader = false
      self.setPeripheralsToTable(self.mighties)
      self.saveMightyDevice()
    default: break
    }
  }
  
  //scanner delegate
  func scanner(_ scanner: MightyScanProtocol, foundMighty peripheral: MightyPeripheral) -> () {
    let appendScannedPeripheralClosure = { [unowned self] in
      self.mighties.append(peripheral)
      self.tableDelegate.peripherals = self.mighties
      self.tableDataSource.appendPeripheral(peripheral)
      self.currentState = .mightyDeviceFound
    }
    
    if let storedMightyInfo = initialMighty {
      if storedMightyInfo.identifier == peripheral.identifier {
        self.stopScan()
        if self.currentUser != nil {
          self.connectTo(peripheral: peripheral, isAutomatic: true, peripheralChangedCompletion: {})
          //self.showAutoconnectAlert()
        } else {
          self.currentState = .interactorError(.noMightyLoginData)
        }
      } else {
        appendScannedPeripheralClosure()
      }
    } else {
      appendScannedPeripheralClosure()
    }
  }
  func scanner(_ scanner: MightyScanProtocol, lostMighty peripheral: MightyPeripheral) -> () {
    if let index = mighties.index(where: {$0.identifier == peripheral.identifier}) {
      mighties.remove(at: index)
      tableDelegate.peripherals = mighties
      tableDataSource.removePeripheral(peripheral)
    } else {
      print("Lost unknown migty")
    }
    if mighties.count == 0 {
      self.currentState = .noDeviceFoundYet
    }
  }
  
  func scanner(_ scanner: MightyScanProtocol, scanFailed error: MightyScannerError) {
    switch error {
    case .bluetoothDisabled: break
    case .bluetoothUnsupported:
      self.currentState = .noBluetooth(false)
      self.setStateToTable(.bluetoothNotSupported)
    }
  }
  func scanner(_ scanner: MightyScanProtocol, bluetoothStateChanged state: BluetoothState) {
    switch state {
    case .enabled:
      self.setStateToTable(.bluetoothEnabled)
      self.currentState = .noDeviceFoundYet
    case .disabled:
      self.currentState = .noBluetooth(true)
      self.setStateToTable(.bluetoothDisabled)
    case .unknown:
      self.setStateToTable(.unknown)
    }
  }
  
  //MARK: Mighties management
  private func setupTableDelegate() {
    if tableDelegate != nil {
      tableDelegate.didSelectDevice = { [unowned self] (peripheral) in
        if self.connectedMighty != nil {
          if self.connectedMighty! == peripheral {
            let currentName = MightyNameUtility.displayNameFromMightyPeripheralName(peripheral.name)
            self.needToRenameDeviceWith?(currentName) { [unowned self] (newName) in
              if self.connectedMighty != nil {
                self.connectedMighty!.name = newName
                var renamedPeripheral = peripheral
                renamedPeripheral.name = newName
                self.tableDataSource.updatePeripheral(renamedPeripheral)
                self.tableDelegate.peripherals = [self.connectedMighty!]
              }
            }
          }
        }
      }
      
      tableDelegate.deviceDisconnectedHandler = { [unowned self] (peripheral) in
        self.disconnectCurrentPeripheral()
      }
      
      tableDelegate.headsetDisconnectedHandler = { [unowned self] (headset) in
        if headset.Status == UInt64(BTHeadsetStatus.connect.rawValue) {
          self.disconnectHeadset(headset)
        } else if headset.Status == UInt64(BTHeadsetStatus.pair.rawValue) {
          self.unpairHeadset(headset)
        }
      }
    }
  }
  
  private func setUpLoginService() {
    mightyLoginService.BLECommunicationEventsHandler = { [weak self] (state) in
      if self != nil {
        switch state {
        case .bluetoothEnabled:
          self!.setStateToTable(.bluetoothEnabled)
          self!.currentState = .noDeviceFoundYet
        case .bluetoothDisabled:
          self!.setStateToTable(.bluetoothDisabled)
          self!.currentState = .noBluetooth(true)
         // self!.hideAutoconnectAlertIfNeeded(completion: {})
        default: break
        }
      }
    }
    
    mightyLoginService.mightyComunicationEventsHandler = { [weak self] (state) in
      if self != nil {
        switch state {
        case .mightyConnected:
          self?.synchronizeCredentials()
        case .mightyDisconnected, .connectionFailed:
          self!.headsets = []
          self!.connectedHeadset = nil
          if self!.mightyLoginService.BLECommunicationState == .bluetoothEnabled {
            self!.currentState = .noDeviceFoundYet
          } else {
            self!.currentState = .noBluetooth(true)
          }
          self!.scan()
          //self!.hideAutoconnectAlertIfNeeded(completion: {})
        default: break
        }
      }
    }
  }
  
  private func setupTableDatasource() {
    if tableDataSource != nil {
      tableDataSource.mightyButtonPressed = { [unowned self] (peripheral) in
        self.stopScan()
        if self.currentUser != nil {
          self.connectTo(peripheral: peripheral, isAutomatic: false, peripheralChangedCompletion: {})
        } else {
          self.currentState = .interactorError(.noMightyLoginData)
        }
      }
      tableDataSource.headsetButtonPressed = { [unowned self] (headset) in
        if (!self.tableDataSource.hasHeadsetsInConnectingState()) && (!self.tableDataSource.hasHeadsetsInPairingState()) {
          if headset.Status == UInt64(BTHeadsetStatus.pair.rawValue) {
            self.connectHeadset(headset)
          } else {
            self.pairHeadset(headset)
          }
        } else {
          self.headsetErrorOccured?(.connectionWhileCnnectionInProgress)
        }
      }
    }
  }
  
  private func connectTo(peripheral: MightyPeripheral, isAutomatic: Bool, peripheralChangedCompletion: @escaping () -> ()) {
    self.tableDelegate.showMightyHeader = true
    self.setPeripheralsToTable([peripheral])
    self.tableDataSource.setState(.deviceConnecting, for: peripheral)
    self.connectingMighty = peripheral
    self.currentState = .prepareToConnect(isAutomatic)
    self.peripheralOwner.changePeripheral(peripheral.identifier, completion: {
      self.currentState = .connectingToMighty(isAutomatic)
      peripheralChangedCompletion()
    })
  }
  
  func disconnectCurrentPeripheral() {
    self.initialMighty = nil
    self.currentState = .noDeviceFoundYet
    self.headsets = []
    self.connectedHeadset = nil
    self.peripheralOwner.changePeripheral(nil, completion: { [weak self] in
      self?.scan()
    })
  }
  
  private func synchronizeCredentials() {
    self.currentUser.Status = 0
    self.mightyLoginService.sendCredentials(appInfo: applicationInfo, mightyCloud: self.currentUser, musicService: currentMusicCredentialsInfo, completion: { [weak self] (result) in
      if self != nil {
        switch result {
        case .success(let status):
          //hideAutoconnectAlertIfNeeded
          let statusAfterHiding = self!.mightyLoginService.mightyCommunicationState
          if statusAfterHiding == .mightyConnected {
            self!.currentState = .mightyAuthentificated(status)
            if self!.handleHeadsets {
              self!.retriveHeadsetHistory()
            }
          }
        case .error(let error):
          //hideAutoconnectAlertIfNeeded ...
          switch error {
          case .mightyDeviceAlreadyHasMightyCloudAccount:
            self!.currentState = .mightyCloudAccountsConflict
          case .mightyDeviceAlreadyHasMusicAccount:
            self!.currentState = .musicServiceAccountsConflict
          default:
            self!.currentState = .mightyConnectionError(error)
            self!.disconnectCurrentPeripheral()
          }
        }
      }
    })
  }
  
  func resolveAccountConflict(rewrite: Bool) {
    if rewrite {
      self.mightyLoginService.resolveSendCredentialsConflict(rewrite: true, completion: { [unowned self] (result) in
        switch result {
        case .success(let status):
          self.currentState = .mightyAuthentificated(status)
        case .error(let error):
          switch error {
          case .mightyDeviceAlreadyHasMusicAccount:
            self.currentState = .musicServiceAccountsConflict
          default:
            self.currentState = .mightyConnectionError(error)
            self.disconnectCurrentPeripheral()
          }
        }
      })
    } else {
      self.mightyLoginService.resolveSendCredentialsConflict(rewrite: false, completion: { (result) in
        self.tableDataSource.setState(.notConnected, for: self.connectingMighty!)
        self.tableDelegate.showMightyHeader = false
        self.setPeripheralsToTable(self.mighties)
        self.currentState = .noDeviceFoundYet
        self.peripheralOwner.changePeripheral(nil, completion: { [unowned self] in
          self.scan()
        })
      })
    }
  }
  
  private func setPeripheralsToTable(_ peripherals: [MightyPeripheral]) {
    tableDelegate.peripherals = peripherals
    tableDataSource.peripherals = peripherals
  }
  
  private func setStateToTable(_ state: DeviceBLEState) {
    tableDelegate.bleState = state
    tableDataSource.bleState = state
  }
  
  func saveMightyDevice() {
    if connectedMighty == nil {
      self.saveMightyOperation?(nil)
      return
    }
    let description = MightyDescription(identifier: connectedMighty!.identifier)
    self.saveMightyOperation?(description)
  }
  
  //MARK: Headsets
  private func retriveHeadsetHistory() {
    mightyHeadsetService.retriveHeadsetsHistory { [weak self] (result) in
      switch result {
      case .success(let headsets):
        if self?.connectedMighty != nil {
          self?.headsets = headsets
        }
        if let index = headsets.firstIndex(where: { (headset) -> Bool in
          return headset.Status == BTHeadsetStatus.connect.rawValue
        }) {
          self?.connectedHeadset = headsets[index]
        }
      case .error(let error):
        print("Error Retriving headsets: code: \(error.code), domain: \(error.errorDomain)")
      }
    }
  }
  
  func scanForNewHeadseats(completion: @escaping ([BTScanList]) -> ()) {
    mightyHeadsetService.retriveAllHeadsets { [weak self] (result) in
      switch result {
      case .success(let headsets):
        self?.headsets = headsets
        self?.tableDataSource.headsets = headsets
        completion(headsets)
      case .error(_):
        completion([])
      }
    }
  }
  
  private func setupHeadsetsService() {
    mightyHeadsetService.startWorkWithService()
  }
  
  private func connectHeadset(_ headset: BTScanList) {
    self.tableDataSource.setConnectionState(.connecting, for: headset)
    mightyHeadsetService.connectHeadset(headset: headset) { [weak self] (result) in
      if self != nil {
        switch result {
        case .success(_):
          self!.connectedHeadset = headset
          self!.setStatus(.connect, for: headset)
        case .error(let error):
          self!.tableDataSource.setPairingState(.paired, for: headset)
          self!.headsetErrorOccured?(.connectionFailed(error))
        }
      }
    }
  }
  
  private func pairHeadset(_ headset: BTScanList) {
    self.tableDataSource.setPairingState(.pairing, for: headset)
    mightyHeadsetService.pairHeadset(headset: headset) { [weak self] (result) in
      if self != nil {
        switch result {
        case .success(_):
          self!.tableDataSource.setPairingState(.paired, for: headset)
          self!.connectedHeadset = headset
          self!.setStatus(.connect, for: headset)
        case .error(let error):
          self!.tableDataSource.setPairingState(.unpaired, for: headset)
          DispatchQueue.main.async {
            self!.headsetErrorOccured?(.connectionFailed(error))
          }
        }
      }
    }
  }
  
  private func unpairHeadset(_ headset: BTScanList) {
    mightyHeadsetService.unpairHeadset(headset: headset) { [weak self] (result) in
      self?.tableDataSource.setPairingState(.unpaired, for: headset)
      if let index = self?.headsets.index(where: {$0.MacID == headset.MacID}) {
        self?.headsets.remove(at: index)
      }
    }
  }
  
  private func disconnectHeadset(_ headset: BTScanList) {
    self.tableDataSource.setConnectionState(.connecting, for: headset)
    mightyHeadsetService.disconnectHeadset(headset: headset) { [weak self] (result) in
      self?.tableDataSource.setPairingState(.paired, for: headset)
      switch result {
      case .success(_):
        self?.setStatus(.pair, for: headset)
      case .error(let error):
        self!.headsetErrorOccured?(.disconnectFailed(error))
      }
    }
  }
  
  private func setStatus(_ status: BTHeadsetStatus, for headset: BTScanList) {
    if let index = headsets.index(where: {$0.MacID == headset.MacID}) {
      headsets[index].Status = UInt64(status.rawValue)
    }
  }

  deinit {
  }
}
