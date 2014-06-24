############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   express = Npm.require 'express'
   cookieParser = Npm.require 'cookie-parser'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'

   # Fast MIME Multipart parsing of generic HTTP POST request bodies

   dice_multipart = (req, callback) ->
      callback = share.bind_env callback
      boundary = share.find_mime_boundary req

      unless boundary
        err = new Error('No MIME multipart boundary found for dicer')
        return callback err

      fileStream = null

      d = new dicer { boundary: boundary }

      d.on 'part', (p) ->
         p.on 'header', (header) ->
            RE_FILE = /^form-data; name="file"; filename="([^"]+)"/
            for k, v of header
               if k is 'content-type'
                  ft = v
               if k is 'content-disposition'
                  if re = RE_FILE.exec(v)
                     fileStream = p
                     fn = re[1]
            callback(null, fileStream, fn, ft)

      d.on 'error', (err) ->
        callback err

      d.on 'finish', () ->
         unless fileStream
            callback(new Error "No file in multipart POST")

      req.pipe(d)

   # Handle a generic HTTP POST file upload

   # This curl command should be properly handled by this code:
   # % curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
   #        -F 'file=@"universe.png";type=image/png' -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

   post = (req, res, next) ->

      # Parse MIME Multipart request body
      dice_multipart req, (err, fileStream, filename, filetype) =>
         if err
            console.warn('Error parsing POST body', err)
            res.writeHead(500)
            res.end()
            return

         # Handle filename or filetype data when included
         req.gridFS.contentType = filetype if filetype
         req.gridFS.filename = filename if filename

         # Write the file data.  No chunks here, this is the whole thing
         stream = @upsertStream req.gridFS
         if stream
            fileStream.pipe(stream)
               .on 'close', () ->
                  res.writeHead(200)
                  res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end()
         else
            res.writeHead(410)
            res.end()

   # Handle a generic HTTP GET request
   # This also handles HEAD requests
   # If the request URL has a "?download=true" query, then a browser download response is triggered

   get = (req, res, next) ->

      headers =
         'Content-type': req.gridFS.contentType
         'Content-MD5': req.gridFS.md5
         'Content-Length': req.gridFS.length
         'Last-Modified': req.gridFS.uploadDate.toUTCString()

      # Trigger download in browser, optionally specify filename.
      if req.query.download or req.query.filename
         filename = req.query.filename ? req.gridFS.filename
         headers['Content-Disposition'] = "attachment; filename=\"#{filename}\""

      # HEADs don't have a body
      if req.method is 'HEAD'
         res.writeHead 204, headers
         res.end()
         return

      # Send the file
      stream = @findOneStream { _id: req.gridFS._id }
      if stream
         res.writeHead 200, headers
         stream.pipe(res)
               .on 'close', () ->
                  res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end(err)
      else
         res.writeHead(410)
         res.end()

   # Handle a generic HTTP PUT request

   # This curl command should be properly handled by this code:
   # % curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -T "universe.png" -H 'Content-Type: image/png' -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   put = (req, res, next) ->

      # Handle content type if it's present
      if req.headers['content-type']
         req.gridFS.contentType = req.headers['content-type']

      # Write the file
      stream = @upsertStream req.gridFS
      if stream
         req.pipe(stream)
            .on 'close', () ->
               res.writeHead(200)
               res.end()
            .on 'error', (err) ->
               res.writeHead(500)
               res.end(err)
      else
         res.writeHead(404)
         res.end("#{req.url} Not found!")

   # Handle a generic HTTP DELETE request

   # This curl command should be properly handled by this code:
   # % curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   del = (req, res, next) ->

      @remove req.gridFS
      res.writeHead(204)
      res.end()

   # Setup all of the application specified paths and file lookups in express
   # Also performs allow/deny permission checks for POST/PUT/DELETE

   build_access_point = (http) ->

      # Loop over the app supplied http paths
      for r in http

         # Add an express middleware for each application REST path
         @router[r.method] r.path, do (r) =>

            getDep = true

            (req, res, next) =>
               # params and queries literally named "_id" get converted to ObjectIDs automatically
               req.params._id = new Meteor.Collection.ObjectID("#{req.params._id}") if req.params?._id?
               req.query._id = new Meteor.Collection.ObjectID("#{req.query._id}") if req.query?._id?

               # Build the path lookup mongoDB query object for the gridFS files collection
               lookup = r.lookup? req.params or {}, req.query or {}
               unless lookup?
                  # No lookup returned, so bailing
                  res.writeHead(500)
                  res.end()
                  return
               else
                  # Perform the collection query
                  req.gridFS = @findOne lookup
                  unless req.gridFS
                     res.writeHead(404)
                     res.end()
                     return

                  # Make sure that the requested method is permitted for this file in the allow/deny rules
                  switch req.method
                     when 'HEAD', 'GET'
                        unless @allows.read.length is 0 and @denys.read.length is 0 or
                               share.check_allow_deny.bind(@) 'read', req.meteorUserId, req.gridFS
                           res.writeHead(403)
                           res.end()
                           return
                        else if @allows.read.length is 0 and @denys.read.length is 0 and getDep
                           console.warn '***********************************************************************'
                           console.warn '** HTTP GET to a fileCollection without one or more "read"'
                           console.warn '** "allow/deny rules is deprecated.'
                           console.warn '**'
                           console.warn '** As of v0.3.0 all fileCollections implementing HTTP GET will need to'
                           console.warn '** implement at least one "read" allow rule that returns "true".'
                           console.warn '**'
                           console.warn '** See:'
                           console.warn '** https://github.com/vsivsi/meteor-file-collection/#fcallowoptions'
                           console.warn '***********************************************************************'
                           getDep = false
                     when 'POST', 'PUT'
                        unless share.check_allow_deny.bind(@) 'write', req.meteorUserId, req.gridFS
                           res.writeHead(403)
                           res.end()
                           return
                     when 'DELETE'
                        unless share.check_allow_deny.bind(@) 'remove', req.meteorUserId, req.gridFS
                           res.writeHead(403)
                           res.end()
                           return
                     else
                        res.writeHead(500)
                        res.end()
                        return

                  next()

      # Add all of generic request handling methods to the express route
      @router.route('/*')
         .all (req, res, next) ->  # Make sure a file has been selected by some rule
            unless req.gridFS
               res.writeHead(404)
               res.end()
               return
            next()
         .head(get.bind(@))   # Generic HTTP method handlers
         .get(get.bind(@))
         .put(put.bind(@))
         .post(post.bind(@))
         .delete(del.bind(@))
         .all (req, res, next) ->   # Unkown methods are denied
            res.writeHead(500)
            res.end()

   # Performs a meteor userId lookup by hased access token

   lookup_userId_by_token = (authToken) ->
      userDoc = Meteor.users?.findOne
         'services.resume.loginTokens':
            $elemMatch:
               hashedToken: Accounts?._hashLoginToken(authToken)
      return userDoc?._id or null

   # Express middleware to convert a Meteor access token provided in an HTTP request
   # to a Meteor userId attached to the request object as req.meteorUserId

   tokenWarning = false

   handle_auth = (req, res, next) ->
      unless req.meteorUserId?
         # Lookup userId if token is provided in HTTP heder
         if req.headers?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.headers['x-auth-token']
         # Or as a URL query of the same name
         else if req.cookies?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.cookies['x-auth-token']
         else if req.query?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.query['x-auth-token']
            unless tokenWarning
               tokenWarning = true
               console.warn '***********************************************************************'
               console.warn '** Sending x-auth-token using URL queries is inherently dangerous and'
               console.warn '** support for it is now deprecated. Please transition to using'
               console.warn '** either the X-Auth-Token HTTP Header or HTTP Cookie.'
               console.warn '**'
               console.warn '** As of v0.3.0 all support for using URL queries to send x-auth-token'
               console.warn '** values will be removed.'
               console.warn '***********************************************************************'
      next()

   # Set up all of the middleware, including optional support for Resumable.js chunked uploads
   share.setupHttpAccess = (options) ->
         r = express.Router()
         r.use express.query()   # Parse URL query strings
         r.use cookieParser()    # Parse cookies
         r.use handle_auth       # Turn x-auth-tokens into Meteor userIds
         WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))

         # Set up support for resumable.js if requested
         if options.resumable
            share.setup_resumable.bind(@)()

         # Setup application HTTP REST interface
         @router = express.Router()
         build_access_point.bind(@)(options.http, @router)
         WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(@router))
