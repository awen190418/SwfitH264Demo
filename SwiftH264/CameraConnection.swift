//
//  CameraConnection.swift
//  zooby
//
//  Created by Kevin Pleitez on 12/27/19.
//  Copyright © 2019 Kevin Pleitez. All rights reserved.
//

import Network
import Foundation

protocol CameraConnectionListener{
    func receiveStreamData(data:Data,size:Int)
}

class CameraConnection{
    var connection: NWConnection?
    var queue: DispatchQueue
    var listener: CameraConnectionListener?
    //sending notification when flag receiving change
    var receiving = false{
        didSet{
            let data:[String:Bool] = ["receiving":self.receiving]
            //NotificationCenter.default.post(name: .cameraConnectionReceiving, object: self, userInfo: data)
        }
    }
    var host: NWEndpoint
    var parameters: NWParameters
    init(queue: DispatchQueue) {
        self.queue = queue
        let ip = "10.10.10.1"
        host = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: 8088)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 2
        parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = true
    }
    
    func setListener(_ l:CameraConnectionListener) {
        self.listener = l
    }
    
    func  startStreaming(){
        self.receiving = false
        if connection != nil{
            connection!.forceCancel()
        }
        connection = NWConnection(to: host, using: parameters)
        connection!.stateUpdateHandler = self.stateDidChange(to:)
        receiveData()
        connection!.start(queue: queue)
    }
    
    func stopStreaming(){
        if connection != nil {
            connection!.cancel()
        }
    }
    
    func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .setup:
            print("setup")
            break
        case .waiting(let error):
                if connection != nil{
                    connection?.cancel()
                    receiving = false
                    self.queue.asyncAfter(deadline: .now() + 1){
                        if !self.receiving {
                            self.connection = nil
                            //self.startStreaming()
                            //NotificationCenter.default.post(name: .cameraConnectionDestroy, object: self, userInfo: nil)
                        }
                    }
                    
                }
            print("waiting ", error.localizedDescription)
            break
        case .preparing:
            print("preparing")
            break
        case .ready:
            print("ready")
                let message = "/VDO?PARM=1,2,3 HTTP/1.0\n\n"
                connection!.send(content: message.data(using: .utf8), completion: NWConnection.SendCompletion.contentProcessed(({ (error) in
                    if let err = error {
                        print("Sending error \(err)")
                    } else {
                        print("Sent successfully")
                        self.queue.asyncAfter(deadline: .now() + 1, execute: {
                            if !self.receiving {
                                self.startStreaming()
                            }
                        })
                    }
                })))
            break
        case .failed(let error):
             receiving = false
            print("failed ", error.debugDescription)
            break
        case .cancelled:
            print("cancelled")
            receiving = false
            break
        @unknown default:
            print("unknown")
        }
    }
    
    @objc func readData(){
        print("reading data")
    }
    
    func receiveData(){
        connection?.receive(minimumIncompleteLength: 256, maximumLength: 1024*10) { (data, context, boolean, error) in
            print("CAMERA DATA",data.debugDescription)
                if data != nil{
                    self.receiving = true
                    self.listener?.receiveStreamData(data: data!, size: data!.count)
                    self.receiveData()
                }
                else{
                    self.receiving = false
                }
               
        }
    }
    
}
