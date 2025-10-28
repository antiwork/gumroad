/*Copyright (c) 2014, TT Labs, Inc.
 All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

 Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

 Neither the name of the TT Labs, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.*/


/***************************************************************************************************
 *                                                                                                  *
 *  version 0.0.2                                                                                  *
 *                                                                                                  *
 *  TODO:                                                                                           *
 *       calculate MD5s and send with PUTs                                                          *
 *       post eTags to application server to allow resumabilit after client-side crash/restart      *
 *                                                                                                  *
 *                                                                                                  *
 ***************************************************************************************************/


var Evaporate = function(config){

  this.supported = !((typeof(File)=='undefined') ||
    (typeof(Blob)=='undefined') ||
    !(!!Blob.prototype.webkitSlice || !!Blob.prototype.mozSlice || Blob.prototype.slice) ||
    config.testUnsupported);

  if(!this.supported){
    return;
  }


  var PENDING = 0, EVAPORATING = 2, COMPLETE = 3, PAUSED = 4, CANCELED = 5, ERROR = 10, ABORTED = 20, ETAG_OF_0_LENGTH_BLOB = '"d41d8cd98f00b204e9800998ecf8427e"';

  var _ = this;
  var files = [];

  var con = extend({

    logging: false,
    maxConcurrentParts: 5,
    partSize: 100 * 1024 * 1024,
    retryBackoffPower: 2,
    maxRetryBackoffSecs: 300,
    progressIntervalMS: 1000,
    maxFileSize: null,
    s3Endpoint: 'https://s3.amazonaws.com'


  }, config);

  var AWS_URL = con.s3Endpoint;

//con.simulateStalling =  true

  _.uploadInitiated = function(id) {

  };

  _.add = function(file){

    l.d('add');
    var err;
    if (typeof file == 'undefined'){
      return 'Missing file';
    }
    if (typeof file.name == 'undefined'){
      err = 'Missing attribute: name  ';
    }
    if (con.maxFileSize && file.file.size > con.maxFileSize) {
      err = 'File size too large. Maximum size allowed is ' + readableFileSize(con.maxFileSize);
    }
    /*if (!(file.file instanceof File)){
     err += '.file attribute must be instanceof File';
     }*/
    if (err){return err;}

    var newId = addFile(file);
    asynProcessQueue();
    return newId;
  };

  _.cancel = function(id){

    l.d('cancel ', id);
    if (files[id]){
      files[id].stop();
      return true;
    } else {
      return false;
    }
  };

  _.pause = function(id){


  };

  _.resume = function(id){


  };

  _.forceRetry = function(){


  };

  var l = {d:function(){}, w: function(){}, e:function(){}};

  if(con.logging && console && console.log){
    l = console;
    l.d = l.log;

    if (console.warn){
      l.w = l.warn;
    }else{
      l.w = l.log;
    }

    if (console.error){
      l.e = l.error;
    }else{
      l.e = l.log;
    }
  }


  function addFile(file){

    var id = files.length
      , fileUpload = new FileUpload(extend({
        progress: function(){},
        complete: function(){},
        cancelled: function(){},
        info: function(){},
        warn: function(){},
        error: function(){},
        initiated: function(){}
      },file,{
        id: id,
        status: PENDING,
        priority: 0,
        onStatusChange: onFileUploadStatusChange,
        loadedBytes: 0,
        sizeBytes: file.file.size
      }));
    files.push(fileUpload);
    fileUpload.initiated(id);
    return id;
  }

  function onFileUploadStatusChange(){

    l.d('onFileUploadStatusChange');
    processQueue();

  }


  function asynProcessQueue(){

    setTimeout(processQueue,1);
  }


  function processQueue(){

    l.d('processQueue   length: ' + files.length);
    var next = -1, priorityOfNext = -1, readyForNext = true;
    files.forEach(function(file,i){

      if (file.priority > priorityOfNext && file.status == PENDING){
        next = i;
        priorityOfNext = file.priority;
      }

      if (file.status == EVAPORATING){
        readyForNext = false;
      }
    });

    if (readyForNext && next >= 0){
      files[next].start();
    }
  }


  function FileUpload(file){

    var me = this, parts = [], progressTotalInterval, progressPartsInterval, countUploadAttempts = 0, xhrs = [];
    extend(me,file);

    me.start = function(){

      l.d('starting FileUpload ' + me.id);

      setStatus(EVAPORATING);
      initiateUpload();
      monitorTotalProgress();
      monitorPartsProgress();
    };

    me.stop = function(){

      l.d('stopping FileUpload ', me.id);
      me.cancelled();
      me.info('upload canceled');
      setStatus(CANCELED);
      cancelAllRequests();
    };


    function setStatus(s){
      if (s == COMPLETE || s == ERROR || s == CANCELED){
        clearInterval(progressTotalInterval);
        clearInterval(progressPartsInterval);
      }
      me.status = s;
      me.onStatusChange();
    }


    function cancelAllRequests(){
      l.d('cancelAllRequests()');

      xhrs.forEach(function(xhr,i){
        xhr.abort();
      });
    }


    function initiateUpload(){ // see: http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadInitiate.html

      var initiate = {
        method: 'POST',
        path: '/' + con.bucket + '/' + me.name + '?uploads',
        step: 'initiate',
        x_amz_headers: me.xAmzHeadersAtInitiate,
        contentType: me.mimeType
      };

      initiate.onErr = function(xhr){
        l.d('onInitiateError for FileUpload ' + me.id);
        setStatus(ERROR);
      };

      initiate.on200 = function(xhr){

        var match = xhr.response.match(/<UploadId\>(.+)<\/UploadId\>/);
        if (match && match[1]){
          me.uploadId = match[1];
          l.d('requester success. got uploadId ' + me.uploadId);
          makeParts();
          processPartsList();
        }else{
          initiate.onErr();
        }
      };

      setupRequest(initiate);
      authorizedSend(initiate);
    }


    function uploadPart(partNumber){  //http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadUploadPart.html

      var backOff, hasErrored, upload, part;

      part = parts[partNumber];

      part.status = EVAPORATING;
      countUploadAttempts++;
      part.loadedBytesPrevious = null;

      backOff = part.attempts++ === 0 ? 0 : 1000 * Math.min(
        con.maxRetryBackoffSecs,
        Math.pow(con.retryBackoffPower,part.attempts-2)
      );
      l.d('uploadPart #' + partNumber + '     will wait ' + backOff + 'ms to try');

      upload = {
        method: 'PUT',
        path: '/' + con.bucket + '/' + me.name + '?partNumber='+partNumber+'&uploadId='+me.uploadId,
        step: 'upload #' + partNumber,
        attempts: part.attempts,
        contentType: me.mimeType
      };
// TODO: add md5

      upload.onErr = function (xhr, isOnError){

        var msg = 'problem uploading part #' + partNumber + ',   http status: ' + xhr.status +
          ',   hasErrored: ' + !!hasErrored + ',   part status: ' + part.status +
          ',   readyState: ' + xhr.readyState + (isOnError ? ',   isOnError' : '');

        l.w(msg);
        me.warn(msg);

        if (hasErrored){
          return;
        }
        hasErrored = true;

        if (xhr.status == 404){
          var errMsg = '404 error resulted in abortion of both this part and the entire file.';
          l.w(errMsg + ' Server response: ' + xhr.response);
          me.error(errMsg);
// TODO: kill off other uploading parts when file is aborted
          part.status = ABORTED;
          setStatus(ABORTED);
        } else {
          part.status = ERROR;
          part.loadedBytes = 0;
          processPartsList();
        }
        xhr.abort();
// TODO: does AWS have other error codes that we can handle?
      };

      upload.on200 = function (xhr){

        var eTag = xhr.getResponseHeader('ETag'), msg;
        l.d('uploadPart 200 response for part #' + partNumber + '     ETag: ' + eTag);
        if (eTag != ETAG_OF_0_LENGTH_BLOB){
          part.eTag = eTag;
          part.status = COMPLETE;
        }else{
          part.status = ERROR;
          part.loadedBytes = 0;
          msg = 'eTag matches MD5 of 0 length blob for part #' + partNumber  + '   Retrying part.';
          l.w(msg);
          me.warn(msg);
        }
        processPartsList();
      };

      upload.onProgress = function (evt){
        part.loadedBytes = evt.loaded;
      };

      var slicerFn = (me.file.slice ? 'slice' : (me.file.mozSlice ? 'mozSlice' : 'webkitSlice'));
// browsers' implementation of the Blob.slice function has been renamed a couple of times, and the meaning of the 2nd parameter changed. For example Gecko went from slice(start,length) -> mozSlice(start, end) -> slice(start, end). As of 12/12/12, it seems that the unified 'slice' is the best bet, hence it being first in the list. See https://developer.mozilla.org/en-US/docs/DOM/Blob for more info.

      upload.toSend = function() {
        var slice= me.file[slicerFn](part.start, part.end);
        l.d('sending part # ' + partNumber + ' (bytes ' + part.start + ' -> ' + part.end + ')  reported length: ' + slice.size);
        if (slice.size === 0){
          l.w('  *** WARN: blob reporting size of 0 bytes. Will try upload anyway..');
        }
        return slice;
      };

      upload.onFailedAuth = function(xhr){

        var msg = 'onFailedAuth for uploadPart #' + partNumber + '.   Will set status to ERROR';
        l.w(msg);
        me.warn(msg);
        part.status = ERROR;
        part.loadedBytes = 0;
        processPartsList();
      };

      setupRequest(upload);

      setTimeout(function(){
        authorizedSend(upload);
        l.d('upload #',partNumber,upload);
      },backOff);

      part.uploader = upload;
    }


    function abortPart(partNumber){

      var part = parts[partNumber];

      if (part.uploader.awsXhr){
        part.uploader.awsXhr.abort();
      }
      if (part.uploader.authXhr){
        part.uploader.authXhr.abort();
      }
    }


    function completeUpload(){ //http://docs.amazonwebservices.com/AmazonS3/latest/API/mpUploadComplete.html

      l.d('completeUpload');
      me.info('will attempt to complete upload');

      var completeDoc = '<CompleteMultipartUpload>';
      parts.forEach(function(part,partNumber){
        if (part){
          completeDoc += '<Part><PartNumber>' + partNumber + '</PartNumber><ETag>' + part.eTag + '</ETag></Part>';
        }
      });
      completeDoc += '</CompleteMultipartUpload>';

      var complete = {
        method: 'POST',
        contentType: 'application/xml; charset=UTF-8',
        path: '/' + con.bucket + '/' + me.name + '?uploadId='+me.uploadId,
        step: 'complete'
      };

      complete.onErr = function (){
        var msg = 'Error completing upload.';
        l.w(msg);
        me.error(msg);
        setStatus(ERROR);
      };

      complete.on200 = function(xhr){
        me.complete(xhr);
        setStatus(COMPLETE);
      };

      complete.toSend = function() {
        return completeDoc;
      };

      setupRequest(complete);
      authorizedSend(complete);
    }


    function makeParts(){

      var numParts = Math.ceil(me.file.size / con.partSize);
      for (var part = 1; part <= numParts; part++){

        parts[part] = {
          status: PENDING,
          start: (part-1)*con.partSize,
          end: (part*con.partSize),
          attempts: 0,
          loadedBytes: 0,
          loadedBytesPrevious: null
        };
      }
    }


    function processPartsList(){

      var evaporatingCount = 0, finished = true, anyPartHasErrored = false, stati = [], bytesLoaded = [], info;

      if (me.status != EVAPORATING){
        me.info('will not process parts list, as not currently evaporating');
        return;
      }

      parts.forEach(function(part,i){

        var requiresUpload = false;
        stati.push(part.status);
        if (part){
          switch(part.status){

            case EVAPORATING:
              finished = false;
              evaporatingCount++;
              bytesLoaded.push(part.loadedBytes);
              break;

            case ERROR:
              anyPartHasErrored = true;
              requiresUpload = true;
              break;

            case PENDING:
              requiresUpload = true;
              break;

            default:
              break;
          }

          if (requiresUpload){
            finished = false;
            if (evaporatingCount < con.maxConcurrentParts){
              uploadPart(i);
              evaporatingCount++;
            }
          }
        }
      });


      info = stati.toString() + ' // bytesLoaded: ' + bytesLoaded.toString();
      l.d('processPartsList()  anyPartHasErrored: ' + anyPartHasErrored,info);

      if (countUploadAttempts >= (parts.length-1) || anyPartHasErrored){
        me.info('part stati: ' + info);
      }
// parts.length is always 1 greater than the actually number of parts, because AWS part numbers start at 1, not 0, so for a 3 part upload, the parts array is: [undefined, object, object, object], which has length 4.

      if (finished){
        completeUpload();
      }
    }


    function monitorTotalProgress(){

      progressTotalInterval = setInterval(function(){

        var totalBytesLoaded = 0;
        parts.forEach(function(part,i){
          totalBytesLoaded += part.loadedBytes;
        });

        me.progress(totalBytesLoaded/me.sizeBytes);
      },con.progressIntervalMS);
    }


    /*
     Issue #6 identified that some parts would stall silently.
     The issue was only noted on Safari on OSX. A bug was filed with Apple, #16136393
     This function was addeded as a work-around. It check the progress of each part every 2 minutes.
     If it finds a part that has made no progress in the last 2 minutes then it aborts it. It will then be detected as an error, and restarted in the same manner of any other errored part
     */
    function monitorPartsProgress(){

      progressPartsInterval = setInterval(function(){

        l.d('monitorPartsProgress() ' + Date());
        parts.forEach(function(part,i){

          var healthy;

          if (part.status != EVAPORATING){
            l.d(i,  'not evaporating ');
            return;
          }

          if (part.loadedBytesPrevious === null){
            l.d(i,'no previous ');
            part.loadedBytesPrevious = part.loadedBytes;
            return;
          }

          healthy = part.loadedBytesPrevious < part.loadedBytes;
          if (con.simulateStalling && i == 4){
            if (Math.random() < 0.25){
              healthy = false;
            }
          }

          l.d(i, (healthy ? 'moving. ' : 'stalled.'), part.loadedBytesPrevious, part.loadedBytes);

          if (!healthy){
            setTimeout(function(){
              me.info('part #' + i + ' stalled. will abort. ' + part.loadedBytesPrevious + ' ' + part.loadedBytes);
              abortPart(i);
            },0);
          }

          part.loadedBytesPrevious = part.loadedBytes;
        });
      },2 * 60 * 1000);
    }


    function setupRequest(requester){

      l.d('setupRequest()',requester);

      var dateString = new Date().toUTCString();

      if (con.fetchCurrentServerTimeUrl) {
        dateString = $.ajax({
          type: "GET",
          url: con.fetchCurrentServerTimeUrl,
          async: false,
          cache: false
        }).responseText;
      }

      requester.dateString = dateString;
      requester.x_amz_headers = extend(requester.x_amz_headers,{
        'x-amz-date': requester.dateString
      });

      requester.onGotAuth = function (){

        var xhr = new XMLHttpRequest();
        xhrs.push(xhr);
        requester.awsXhr = xhr;
        var payload = requester.toSend ? requester.toSend() : null;
        var url = AWS_URL + requester.path;

        if (con.simulateErrors && requester.attempts == 1 &&requester.step == 'upload #3'){
          l.d('simulating error by POST part #3 to invalid url');
          url = 'https:///foo';
        }

        xhr.open(requester.method, url);
        xhr.setRequestHeader('Authorization', 'AWS ' + con.aws_key + ':' + requester.auth);

        if (requester.contentType){
          var contentType = requester.contentType;
          if(!contentType.match(';')) {
            contentType += '; charset=UTF-8';
          }
          xhr.setRequestHeader('Content-Type', contentType);
        }

        for (var key in requester.x_amz_headers) {
          if (requester.x_amz_headers.hasOwnProperty(key)) {
            xhr.setRequestHeader(key, requester.x_amz_headers[key]);
          }
        }
        xhr.onreadystatechange = function(){

          if (xhr.readyState == 4){

            if(payload){l.d('  ### ' + payload.size);} // Test, per http://code.google.com/p/chromium/issues/detail?id=167111#c20
            if (xhr.status == 200){
              requester.on200(xhr);
            } else {
              requester.onErr(xhr);
            }
          }
        };

        xhr.onerror = function(){requester.onErr(xhr,true);};

        if (typeof requester.onProgress == 'function'){
          xhr.upload.onprogress = function(evt){
            requester.onProgress(evt);
          };
        }
        xhr.send(payload);
      };

      requester.onFailedAuth = requester.onFailedAuth || function(xhr){
        me.error('Error onFailedAuth for step: ' + requester.step);
        requester.onErr(xhr);
      };
    }


//see: http://docs.amazonwebservices.com/AmazonS3/latest/dev/RESTAuthentication.html#ConstructingTheAuthenticationHeader
    function authorizedSend(authRequester){

      l.d('authorizedSend() ' + authRequester.step);
      var xhr = new XMLHttpRequest();
      xhrs.push(xhr);
      authRequester.authXhr = xhr;
      var url = con.signerUrl+'?to_sign='+makeStringToSign(authRequester);
      var warnMsg;

      for (var param in me.signParams) {
        if (!me.signParams.hasOwnProperty(param)) {continue;}
        url += ('&'+encodeURIComponent(param)+'='+encodeURIComponent(me.signParams[param]));
      }


      xhr.onreadystatechange = function(){

        if (xhr.readyState == 4){

          if (xhr.status == 200 && xhr.response.length == 28){

            l.d('authorizedSend got signature for step: \'' + authRequester.step + '\'    sig: '+ xhr.response);
            authRequester.auth = xhr.response;
            authRequester.onGotAuth();

          } else {
            warnMsg = 'failed to get authorization (readyState=4) for ' + authRequester.step + '.  xhr.status: ' + xhr.status + '.  xhr.response: ' + xhr.response;
            l.w(warnMsg);
            me.warn(warnMsg);
            authRequester.onFailedAuth(xhr);
          }
        }
      };

      xhr.onerror = function(){
        warnMsg = 'failed to get authorization (onerror) for ' + authRequester.step + '.  xhr.status: ' + xhr.status + '.  xhr.response: ' + xhr.response;
        l.w(warnMsg);
        me.warn(warnMsg);
        authRequester.onFailedAuth(xhr);
      };

      xhr.open('GET', url);
      xhr.send();
    }

    function makeStringToSign(request){

      var x_amz_headers = '', to_sign, header_key_array = [];

      for (var key in request.x_amz_headers) {
        if (request.x_amz_headers.hasOwnProperty(key)) {
          header_key_array.push(key);
        }
      }
      header_key_array.sort();

      header_key_array.forEach(function(header_key,i){
        x_amz_headers += (header_key + ':'+ request.x_amz_headers[header_key] + '\n');
      });
      var mimeType = request.contentType;
      if(me.mimeType && request.step != 'complete') {
        mimeType = me.mimeType + "; charset=UTF-8";
      }
      to_sign = request.method+'\n'+
        '\n'+
        (mimeType || '')+'\n'+
        '\n'+
        x_amz_headers +
        request.path;
      return encodeURIComponent(to_sign);
    }
  }


  function extend(obj1, obj2, obj3){

    if (typeof obj1 == 'undefined'){obj1 = {};}

    if (typeof obj3 == 'object'){
      for (var key in obj3){
        obj2[key]=obj3[key];
      }
    }

    for (var key2 in obj2){
      obj1[key2]=obj2[key2];
    }
    return obj1;
  }

  function readableFileSize(size) {
    // Adapted from https://github.com/fkjaekel
    // https://github.com/TTLabs/EvaporateJS/issues/13
    var units = ['B', 'Kb', 'Mb', 'Gb', 'Tb', 'Pb', 'Eb', 'Zb', 'Yb'],
      i = 0;
    while(size >= 1024) {
      size /= 1024;
      ++i;
    }
    return [size.toFixed(2).replace('.00', ''), units[i]].join(" ");
  }
};

module.exports = Evaporate;
