//
//  VGPlayerDownloader.swift
//  Pods
//
//  Created by Vein on 2017/6/23.
//
//

import Foundation
import MobileCoreServices

// MARK: - VGPlayerDownloaderStatus
public struct VGPlayerDownloaderStatus {
    
    static let shared = VGPlayerDownloaderStatus()
    fileprivate var downloadingURLs: NSMutableSet
    fileprivate let downloaderStatusQueue = DispatchQueue(label: "com.vgplayer.downloaderStatusQueue")
    
    init() {
        self.downloadingURLs = NSMutableSet()
    }
    
    public func add(URL: URL) {
        self.downloaderStatusQueue.sync {
            self.downloadingURLs.add(URL)
        }
    }
    
    public func remove(URL: URL) {
        self.downloaderStatusQueue.sync {
            self.downloadingURLs.remove(URL)
        }
    }
    
    public func contains(URL: URL) -> Bool{
        return self.downloadingURLs.contains(URL)
    }
    
    public func urls() -> NSSet {
        return self.downloadingURLs.copy() as! NSSet
    }
}

public protocol VGPlayerDownloaderDelegate: class {
    func downloader(_ downloader: VGPlayerDownloader, didReceiveResponse response: URLResponse)
    func downloader(_ downloader: VGPlayerDownloader, didReceiveData data: Data)
    func downloader(_ downloader: VGPlayerDownloader, didFinishedWithError error: Error?)
}


extension VGPlayerDownloaderDelegate {
    public func downloader(_ downloader: VGPlayerDownloader, didReceiveResponse response: URLResponse) { }
    public func downloader(_ downloader: VGPlayerDownloader, didReceiveData data: Data) { }
    public func downloader(_ downloader: VGPlayerDownloader, didFinishedWithError error: Error?) { }
}

// MARK: - VGPlayerDownloader
open class VGPlayerDownloader: NSObject {
    open fileprivate(set) var url: URL
    open weak var delegate: VGPlayerDownloaderDelegate?
    open var cacheMedia: VGPlayerCacheMedia?
    open var cacheMediaWorker: VGPlayerCacheMediaWorker
    
    fileprivate var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration)
        return session
    }()
    fileprivate var isDownloadToEnd: Bool = false
    fileprivate var actionWorker: VGPlayerDownloadActionWorker?
    
    deinit {
        VGPlayerDownloaderStatus.shared.remove(URL: self.url)
    }
    
    public init(url: URL) {
        self.url = url
        self.cacheMediaWorker = VGPlayerCacheMediaWorker(url: url)
        self.cacheMedia = self.cacheMediaWorker.cacheConfiguration?.cacheMedia
        super.init()
    }
    
    open func dowloaderTask(_ fromOffset: Int64, _ length: Int, _ isEnd: Bool) {
        if isCurrentURLDownloading() {
            handleCurrentURLDownloadingError()
            return
        }
        VGPlayerDownloaderStatus.shared.add(URL: self.url)
        
        var range = NSRange(location: Int(fromOffset), length: length)
        if isEnd {
            if let contentLength = self.cacheMediaWorker.cacheConfiguration?.cacheMedia?.contentLength {
                range.length = Int(contentLength) - range.location
            } else {
                range.length = 0 - range.location
            }
            
        }
        let actions = self.cacheMediaWorker.cachedDataActions(forRange: range)
        self.actionWorker = VGPlayerDownloadActionWorker(actions: actions, url: self.url, cacheMediaWorker: self.cacheMediaWorker)
        self.actionWorker?.delegate = self
        self.actionWorker?.start()
    }
    open func dowloadFrameStartToEnd() {
        if isCurrentURLDownloading() {
            handleCurrentURLDownloadingError()
            return
        }
        VGPlayerDownloaderStatus.shared.add(URL: self.url)
        
        self.isDownloadToEnd = true
        let range = NSRange(location: 0, length: 2)
        let actions = self.cacheMediaWorker.cachedDataActions(forRange: range)
        self.actionWorker = VGPlayerDownloadActionWorker(actions: actions, url: self.url, cacheMediaWorker: self.cacheMediaWorker)
        self.actionWorker?.delegate = self
        self.actionWorker?.start()
        
        
    }
    open func cancel() {
        VGPlayerDownloaderStatus.shared.remove(URL: self.url)
        self.actionWorker?.cancel()
        self.actionWorker?.delegate = nil
        self.actionWorker = nil
    }
    
    open func invalidateAndCancel() {
        VGPlayerDownloaderStatus.shared.remove(URL: self.url)
        self.actionWorker?.cancel()
        self.actionWorker?.delegate = nil
        self.actionWorker = nil
    }
    
    // check
    internal func isCurrentURLDownloading() -> Bool {
        return VGPlayerDownloaderStatus.shared.contains(URL: self.url)
    }
    
    internal func handleCurrentURLDownloadingError() {
        
        if isCurrentURLDownloading() {
            let userInfo = [NSLocalizedDescriptionKey: "URL: \(self.url) alreay in downloading queue."]
            let error = NSError(domain: "com.vgplayer.download", code: -1, userInfo: userInfo)
            self.delegate?.downloader(self, didFinishedWithError: error as Error)
        }
    }
}

// MARK: - VGPlayerDownloadActionWorkerDelegate
extension VGPlayerDownloader: VGPlayerDownloadActionWorkerDelegate {
    
    public func downloadActionWorker(_ actionWorker: VGPlayerDownloadActionWorker, didFinishWithError error: Error?) {
        VGPlayerDownloaderStatus.shared.remove(URL: self.url)
        if error == nil && self.isDownloadToEnd {
            self.isDownloadToEnd = false
            let length = (self.cacheMediaWorker.cacheConfiguration?.cacheMedia?.contentLength)! - 2
            dowloaderTask(2, Int(length), true)
        } else {
            self.delegate?.downloader(self, didFinishedWithError: error)
        }
    }
    
    public func downloadActionWorker(_ actionWorker: VGPlayerDownloadActionWorker, didReceive data: Data, isLocal: Bool) {
        self.delegate?.downloader(self, didReceiveData: data)
    }
    
    public func downloadActionWorker(_ actionWorker: VGPlayerDownloadActionWorker, didReceive response: URLResponse) {
        if self.cacheMedia == nil {
            let cacheMedia = VGPlayerCacheMedia()
            if response.isKind(of: HTTPURLResponse.classForCoder()) {
                
                let HTTPurlResponse = response as! HTTPURLResponse                                  // set header
                let acceptRange = HTTPurlResponse.allHeaderFields["Accept-Ranges"] as? String
                if let bytes = acceptRange?.isEqual("bytes") {
                    cacheMedia.isByteRangeAccessSupported = bytes
                }
                let contentRange = HTTPurlResponse.allHeaderFields["Content-Range"] as? String
                if let last = contentRange?.components(separatedBy: "/").last {
                    cacheMedia.contentLength = Int64(last)!
                }
                
            }
            if let mimeType = response.mimeType {
                let contentType =  UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType as CFString, nil)
                if let takeUnretainedValue = contentType?.takeUnretainedValue() {
                    cacheMedia.contentType = takeUnretainedValue as String
                }
            }
            self.cacheMedia = cacheMedia
            let isSetCacheMedia = self.cacheMediaWorker.set(cacheMedia: cacheMedia)
            if !isSetCacheMedia {
                let nsError = NSError(domain: "com.vgplayer.cacheMedia", code: -1, userInfo: [NSLocalizedDescriptionKey:"Set cache media failed."])
                self.delegate?.downloader(self, didFinishedWithError: nsError as Error)
                return
            }
        }
        self.delegate?.downloader(self, didReceiveResponse: response)
    }
    
    
}
