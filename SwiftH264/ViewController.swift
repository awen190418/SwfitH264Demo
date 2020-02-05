//
//  ViewController.swift
//  SwiftH264
//
//  Created by zhongzhendong on 4/20/16.
//  Copyright © 2016 zhongzhendong. All rights reserved.
//

import UIKit
import VideoToolbox
import AVFoundation

struct NALUPacket {
    var data:Array<UInt8>
    var count:Int32
}

class ViewController: UIViewController, CameraConnectionListener {

    
    
    var formatDesc: CMVideoFormatDescription?
    var decompressionSession: VTDecompressionSession?
    var videoLayer: AVSampleBufferDisplayLayer?
    
    var spsSize: Int = 0
    var ppsSize: Int = 0
    
    var sps: Array<UInt8>?
    var pps: Array<UInt8>?
    
    var nalu_data:Array<UInt8> = []
    var naluList: Array<Array<UInt8>> = []
    let NALU_MAXLEN = 1024 * 1024;
    var nalu_search_state = 0
    var nalu_data_position = 0
    var timer = Timer.init()


    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        nalu_data = Array<UInt8>.init(repeating: 0, count: NALU_MAXLEN)
        videoLayer = AVSampleBufferDisplayLayer()
        
        if let layer = videoLayer {
            layer.frame = CGRect(x: 0, y: 400, width: 300, height: 300)
            layer.videoGravity = AVLayerVideoGravity.resizeAspect
            
            
            let _CMTimebasePointer = UnsafeMutablePointer<CMTimebase?>.allocate(capacity: 1)
            let status = CMTimebaseCreateWithMasterClock( kCFAllocatorDefault, CMClockGetHostTimeClock(),  _CMTimebasePointer )
            layer.controlTimebase = _CMTimebasePointer.pointee
            
            if let controlTimeBase = layer.controlTimebase, status == noErr {
                CMTimebaseSetTime(controlTimeBase, kCMTimeZero);
                CMTimebaseSetRate(controlTimeBase, 1.0);
            }
            
            self.view.layer.addSublayer(layer)
    
        }
        

        
    }

    @IBAction func startClicked(_ sender: UIButton) {
        /*DispatchQueue.global().async {
            let filePath = Bundle.main.path(forResource: "temp", ofType: "h264")
            let url = URL(fileURLWithPath: filePath!)
            self.decodeFile(url)
        }*/
        let cameraConnection = CameraConnection(queue: DispatchQueue.init(label: "video"))
        cameraConnection.setListener(self)
        cameraConnection.startStreaming()
        
        //timer =  Timer.scheduledTimer(withTimeInterval: 0.03333, repeats: true, block: { _ in
        while(true){
            if self.naluList.count > 0 {
                var array = self.naluList.removeFirst()
                self.receivedRawVideoFrame(&array)
            }
        }

        //})
        
    }
    
    func receiveStreamData(data: Data, size: Int) {
        var array = data.withUnsafeBytes{
            [UInt8](UnsafeBufferPointer(start: $0, count: data.count))
        }
        parseDatagram(array, size: array.count)
    }
    
    func decodeFile(_ fileURL: URL) {
        
        let videoReader = VideoFileReader()
        videoReader.openVideoFile(fileURL)
        
        while var packet = videoReader.netPacket() {
            self.receivedRawVideoFrame(&packet)
        }
        
    }
    
    func parseDatagram(_ d:Array<UInt8>,size:Int){
        var n = 0
        while(n < size ){
            
            nalu_data[nalu_data_position] = d[n]
           
            if(nalu_data_position == NALU_MAXLEN - 1){
                nalu_data_position = 0;
                print("NALU overflow")
            }
            nalu_data_position += 1
            switch nalu_search_state{
                case 0...2:
                    if d[n] == 0{
                        nalu_search_state += 1
                    }
                    else{
                        nalu_search_state = 0
                    }
                break
                case 3:
                
                    if(d[n] == 1){
                        nalu_data[0] = 0
                        nalu_data[1] = 0
                        nalu_data[2] = 0
                        nalu_data[3] = 1
                        print("NALU data send to decode")
                        if (nalu_data_position - 4) != 0 {
                            naluList.append(Array(nalu_data[0..<(nalu_data_position - 4)]))
                        }
                        nalu_data_position = 4
                    }
                    nalu_search_state = 0
                break
            default:
                break
            }
            n += 1
           
        }
    }

    
    func receivedRawVideoFrame(_ videoPacket: inout VideoPacket) {
        let position = videoPacket.count
        //replace start code with nal size
        if position != 0 {
            var biglen = CFSwapInt32HostToBig(UInt32(position - 4))
            memcpy(&videoPacket, &biglen, 4)
        }

        
        let nalType = videoPacket[4] & 0x1F
        
        switch nalType {
        case 0x05:
            print("Nal type is IDR frame")
            if createDecompSession() {
                decodeVideoPacket(videoPacket)
            }
        case 0x07:
            print("Nal type is SPS")
            spsSize = position - 4
            sps = Array(videoPacket[4..<position])
        case 0x08:
            print("Nal type is PPS")
            ppsSize = position - 4
            pps = Array(videoPacket[4..<position])
        default:
            print("Nal type is B/P frame")
            decodeVideoPacket(videoPacket)
            break;
        }
        
        print("Read Nalu size \(position)");
    }

    func decodeVideoPacket(_ videoPacket: VideoPacket) {
        
        let position = videoPacket.count
        
        let bufferPointer = UnsafeMutablePointer<UInt8>(mutating: videoPacket)
        
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,bufferPointer, position,
                                                        kCFAllocatorNull,
                                                        nil, 0, position,
                                                        0, &blockBuffer)
        
        if status != kCMBlockBufferNoErr {
            return
        }
        
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [position]
        
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                           blockBuffer,
                                           formatDesc,
                                           1, 0, nil,
                                           1, sampleSizeArray,
                                           &sampleBuffer)
        
        if let buffer = sampleBuffer, let session = decompressionSession, status == kCMBlockBufferNoErr {
            
            let attachments:CFArray? = CMSampleBufferGetSampleAttachmentsArray(buffer, true)
            if let attachmentArray = attachments {
                let dic = unsafeBitCast(CFArrayGetValueAtIndex(attachmentArray, 0), to: CFMutableDictionary.self)
                
                CFDictionarySetValue(dic,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            
            
            //diaplay with AVSampleBufferDisplayLayer
            self.videoLayer?.enqueue(buffer)
            
            DispatchQueue.main.async(execute: {
                self.videoLayer?.setNeedsDisplay()
            })
            
            // or decompression to CVPixcelBuffer
            var flagOut = VTDecodeInfoFlags(rawValue: 0)
            var outputBuffer = UnsafeMutablePointer<CVPixelBuffer>.allocate(capacity: 1)
            
            status = VTDecompressionSessionDecodeFrame(session, buffer,
                                                       [._EnableAsynchronousDecompression],
                                                       &outputBuffer, &flagOut)
            
            if status == noErr {
                print("OK")
            }else if(status == kVTInvalidSessionErr) {
                print("IOS8VT: Invalid session, reset decoder session");
            } else if(status == kVTVideoDecoderBadDataErr) {
                print("IOS8VT: decode failed status=\(status)(Bad data)");
            } else if(status != noErr) {
                print("IOS8VT: decode failed status=\(status)");
            }
        }
    }
    
    func createDecompSession() -> Bool{
        formatDesc = nil
        
        if let spsData = sps, let ppsData = pps {
            let pointerSPS = UnsafePointer<UInt8>(spsData)
            let pointerPPS = UnsafePointer<UInt8>(ppsData)
            
            // make pointers array
            let dataParamArray = [pointerSPS, pointerPPS]
            let parameterSetPointers = UnsafePointer<UnsafePointer<UInt8>>(dataParamArray)
            
            // make parameter sizes array
            let sizeParamArray = [spsData.count, ppsData.count]
            let parameterSetSizes = UnsafePointer<Int>(sizeParamArray)
            
            
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &formatDesc)
            
            if let desc = formatDesc, status == noErr {
                
                if let session = decompressionSession {
                    VTDecompressionSessionInvalidate(session)
                    decompressionSession = nil
                }
                
                var videoSessionM : VTDecompressionSession?
                
                let decoderParameters = NSMutableDictionary()
                let destinationPixelBufferAttributes = NSMutableDictionary()
                destinationPixelBufferAttributes.setValue(NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange as UInt32), forKey: kCVPixelBufferPixelFormatTypeKey as String)
                
                var outputCallback = VTDecompressionOutputCallbackRecord()
                outputCallback.decompressionOutputCallback = decompressionSessionDecodeFrameCallback
                outputCallback.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
                
                let status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                          desc, decoderParameters,
                                                          destinationPixelBufferAttributes,&outputCallback,
                                                          &videoSessionM)
                
                if(status != noErr) {
                    print("\t\t VTD ERROR type: \(status)")
                }
                
                self.decompressionSession = videoSessionM
            }else {
                print("IOS8VT: reset decoder session failed status=\(status)")
            }
        }
        
        return true
    }
    
    func displayDecodedFrame(_ imageBuffer: CVImageBuffer?) {
        
    }

}

private func decompressionSessionDecodeFrameCallback(_ decompressionOutputRefCon: UnsafeMutableRawPointer?, _ sourceFrameRefCon: UnsafeMutableRawPointer?, _ status: OSStatus, _ infoFlags: VTDecodeInfoFlags, _ imageBuffer: CVImageBuffer?, _ presentationTimeStamp: CMTime, _ presentationDuration: CMTime) -> Void {
    
        let streamManager: ViewController = unsafeBitCast(decompressionOutputRefCon, to: ViewController.self)
    
        if status == noErr {
            // do something with your resulting CVImageBufferRef that is your decompressed frame
            streamManager.displayDecodedFrame(imageBuffer);
        }
}

