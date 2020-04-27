//
//  Stream.swift
//  SimpleDALPlugin
//
//  Created by 池上涼平 on 2020/04/25.
//  Copyright © 2020 com.seanchas116. All rights reserved.
//

import Foundation
import Cocoa
import AVFoundation

extension CameraManager {
    class var shared : CameraManager {
        struct Static { static let instance : CameraManager = CameraManager() }
        return Static.instance
    }
}

class CameraManager {
    //ターゲットのカメラがあれば設定（見つからなければデフォルト）
    private let targetDeviceName = ""
//    private let targetDeviceName = "FaceTime HDカメラ（ディスプレイ）"
//    private let targetDeviceName = "FaceTime HD Camera"

    // AVFoundation
    private let session = AVCaptureSession()
    private var captureDevice : AVCaptureDevice!
    private var videoOutput = AVCaptureVideoDataOutput()

    /// セッション開始
    func startSession(delegate:AVCaptureVideoDataOutputSampleBufferDelegate){

        let devices = AVCaptureDevice.devices()
        if devices.count > 0 {
            captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
            // ターゲットが設定されていればそれを選択
            print("\n[接続カメラ一覧]")
            for d in devices {
                if d.localizedName == targetDeviceName {
                    captureDevice = d
                }
                print(d.localizedName)
            }
            print("\n[使用カメラ]\n\(captureDevice!.localizedName)\n\n")
            // セッションの設定と開始
            session.beginConfiguration()
            let videoInput = try? AVCaptureDeviceInput.init(device: captureDevice)
            session.sessionPreset = .low
            session.addInput(videoInput!)
            session.addOutput(videoOutput)
            session.commitConfiguration()
            session.startRunning()
            // 画像バッファ取得のための設定
            let queue:DispatchQueue = DispatchQueue(label: "videoOutput", attributes: .concurrent)
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as AnyHashable as! String : Int(kCVPixelFormatType_32BGRA)]
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
        } else {
            print("カメラが接続されていません")
        }
    }

}

class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    var cvImageBuffer: CVImageBuffer?
    
    /// カメラ映像取得時
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        DispatchQueue.main.sync(execute: {
            connection.videoOrientation = .portrait
            let pixelBuffer:CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
            self.cvImageBuffer = pixelBuffer
//            //CIImage
//            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
//            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
//            let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
//            let rect:CGRect = CGRect.init(x: 0, y: 0, width: w, height: h)
//            let context = CIContext.init()
//            //CGImage
//            let cgimage = context.createCGImage(ciImage, from: rect)
//            //UIImage
//            let image = NSImage(cgImage: cgimage!, size: NSSize(width: w, height: h))
//            //加工してNSImageViewなどに..
        })
    }

}

class Stream: Object {
    var objectID: CMIOObjectID = 0
    let name = "SimpleDALPlugin"
    let width = 1280
    let height = 720
    let frameRate = 30

    let camera = Camera()
    
    private var sequenceNumber: UInt64 = 0
    private var queueAlteredProc: CMIODeviceStreamQueueAlteredProc?
    private var queueAlteredRefCon: UnsafeMutableRawPointer?

    private lazy var formatDescription: CMVideoFormatDescription? = {
        var formatDescription: CMVideoFormatDescription?
        let error = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_422YpCbCr8,
            width: Int32(width), height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard error == noErr else {
            log("CMVideoFormatDescriptionCreate Error: \(error)")
            return nil
        }
        return formatDescription
    }()

    private lazy var clock: CFTypeRef? = {
        var clock = UnsafeMutablePointer<Unmanaged<CFTypeRef>?>.allocate(capacity: 1)

        let error = CMIOStreamClockCreate(
            kCFAllocatorDefault,
            "SimpleDALPlugin clock" as CFString,
            Unmanaged.passUnretained(self).toOpaque(),
            CMTimeMake(value: 1, timescale: 10),
            100, 10,
            clock);
        guard error == noErr else {
            log("CMIOStreamClockCreate Error: \(error)")
            return nil
        }
        return clock.pointee?.takeUnretainedValue()
    }()

    private lazy var queue: CMSimpleQueue? = {
        var queue: CMSimpleQueue?
        let error = CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: 30,
            queueOut: &queue)
        guard error == noErr else {
            log("CMSimpleQueueCreate Error: \(error)")
            return nil
        }
        return queue
    }()

    private lazy var timer: DispatchSourceTimer = {
        let interval = 1.0 / Double(frameRate)
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: { [weak self] in
            self?.enqueueBuffer()
        })
        return timer
    }()

    lazy var properties: [Int : Property] = [
        kCMIOObjectPropertyName: Property(name),
        kCMIOStreamPropertyFormatDescription: Property(formatDescription!),
        kCMIOStreamPropertyFormatDescriptions: Property([formatDescription!] as CFArray),
        kCMIOStreamPropertyDirection: Property(UInt32(0)),
        kCMIOStreamPropertyFrameRate: Property(Float64(frameRate)),
        kCMIOStreamPropertyFrameRates: Property(Float64(frameRate)),
        kCMIOStreamPropertyMinimumFrameRate: Property(Float64(frameRate)),
        kCMIOStreamPropertyFrameRateRanges: Property(AudioValueRange(mMinimum: Float64(frameRate), mMaximum: Float64(frameRate))),
        kCMIOStreamPropertyClock: Property(CFTypeRefWrapper(ref: clock!)),
    ]

    func start() {
        CameraManager.shared.startSession(delegate: camera)

        timer.resume()
    }

    func stop() {
        timer.suspend()
    }

    func copyBufferQueue(queueAlteredProc: CMIODeviceStreamQueueAlteredProc?, queueAlteredRefCon: UnsafeMutableRawPointer?) -> CMSimpleQueue? {
        self.queueAlteredProc = queueAlteredProc
        self.queueAlteredRefCon = queueAlteredRefCon
        return self.queue
    }

    private func createPixelBuffer() -> CVPixelBuffer? {
//        let pixelBuffer = CVPixelBuffer.create(size: CGSize(width: width, height: height))
//        pixelBuffer?.modifyWithContext { [width, height] context in
//            let time = Double(mach_absolute_time()) / Double(1000_000_000)
//            let pos = CGFloat(time - floor(time))
//
//            context.setFillColor(CGColor.init(red: 1, green: 1, blue: 1, alpha: 1))
//            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
//
//            context.setFillColor(CGColor.init(red: 1, green: 0, blue: 0, alpha: 1))
//
//            context.fill(CGRect(x: pos * CGFloat(width), y: 310, width: 100, height: 100))
//        }
        return camera.cvImageBuffer
    }

    private func enqueueBuffer() {
        guard let queue = queue else {
            log("queue is nil")
            return
        }

        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            log("queue is full")
            return
        }

        guard let pixelBuffer = createPixelBuffer() else {
            log("pixelBuffer is nil")
            return
        }

        let currentTimeNsec = mach_absolute_time()

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(currentTimeNsec), timescale: CMTimeScale(1000_000_000)),
            decodeTimeStamp: .invalid
        )

        var error = noErr

        error = CMIOStreamClockPostTimingEvent(timing.presentationTimeStamp, currentTimeNsec, true, clock)
        guard error == noErr else {
            log("CMSimpleQueueCreate Error: \(error)")
            return
        }

        var formatDescription: CMFormatDescription?
        error = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard error == noErr else {
            log("CMVideoFormatDescriptionCreateForImageBuffer Error: \(error)")
            return
        }

        let sampleBufferPtr = UnsafeMutablePointer<Unmanaged<CMSampleBuffer>?>.allocate(capacity: 1)
        error = CMIOSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            formatDescription,
            &timing,
            sequenceNumber,
            UInt32(kCMIOSampleBufferNoDiscontinuities),
            sampleBufferPtr
        )
        guard error == noErr else {
            log("CMIOSampleBufferCreateForImageBuffer Error: \(error)")
            return
        }

        CMSimpleQueueEnqueue(queue, element: sampleBufferPtr.pointee!.toOpaque())
        queueAlteredProc?(objectID, sampleBufferPtr.pointee!.toOpaque(), queueAlteredRefCon)

        sequenceNumber += 1
    }
}
