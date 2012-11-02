#!./node_modules/.bin/coffee
console = require('tracer').colorConsole()
wget    = require 'http-get'
req     = require 'request'
qs      = require 'querystring'
$c      = require 'cheerio'
cookie  = require 'cookie'
_       = require 'underscore'
iconv   = require 'iconv-lite'
sqlite3 = require('sqlite3').verbose()
fs      = require 'fs'
{exec}  = require 'child_process'
path    = require 'path'
async   = require 'async'
urlify  = require 'django-urlify'
stdin   = process.stdin
stdout  = process.stdout
cache   = c = {}
db      = null
already = 0.0
total   = 0.0

ask = (question, format, callback) ->
  stdin.resume()
  stdout.write question + ": "
  stdin.once "data", (data) ->
    data = data.toString().trim()
    if format.test(data)
      callback data
    else
      stdout.write "It should match: " + format + "\n"
      ask question, format, callback

getCred = (cbk)->
  ask "Vk login", /^\S+$/, (login) ->
    ask "Vk password", /^\S+$/, (password) ->
      cache.login = login
      cache.pass = password
      cbk null


login = (cbk)->
  login=c.login
  password=c.pass
  dict =
    act:'login'
    role:'al_frame'
    _origin:'http://vk.com'
    ip_h:'09683976fa4d511986'
    email:login
    pass:password

  req 'http://login.vk.com?act=login', (err,resp,body)->
    $ = $c.load body
    action = $('form').attr('action')
    actData = qs.parse(action)
    dict.ip_h = actData.ip_h
    req.post action, {form:dict}, (err,resp)->
      acc = {}
      for s in (if _.isArray(resp.headers['set-cookie']) then resp.headers['set-cookie'] else [resp.headers['set-cookie']])
        _.extend acc, cookie.parse(s)
      req 'http://vk.com/audio', ->
        cache.id = acc.l
        cbk err

parseAudio = (next)->
  id = c.id
  data =
    act:'load_audios_silent'
    al:1
    gid:0
    id:id
  headers = 
    'User-Agent': 'Opera/9.80 (Macintosh; Intel Mac OS X 10.8.2; U; ru) Presto/2.10.289 Version/12.02'
    Host: 'vk.com'
    Accept: 'text/html, application/xml;q=0.9, application/xhtml+xml, image/png, image/webp, image/jpeg, image/gif, image/x-xbitmap, */*;q=0.1'
    'Accept-Language': 'ru,en;q=0.9,en-US;q=0.8'
    'Referer': 'http://vk.com/feed'
    'Connection': 'Keep-Alive'
    'X-Requested-With': 'XMLHttpRequest'
    'Content-Type': 'application/x-www-form-urlencoded'
  req.post 'http://vk.com/audio', {form:data, headers:headers, encoding: 'binary'}, (err,resp,body)->
    body = new Buffer(body, 'binary')
    body = iconv.decode(body, 'win1251')
    audio = JSON.parse(body.split(/\<\!\>/)[5].replace(/'/g,'"')).all
    cache.audio = audio
    next err

prepareDirectory = (next)->
  cache.dir = "./music-#{c.id}"
  try fs.mkdirSync(c.dir)
  cache.db = db = new sqlite3.Database("#{c.dir}/.db.sqlite")
  cache.db.run """CREATE TABLE IF NOT EXISTS `track` (
              `id` INTEGER PRIMARY KEY,
              `tid` INTEGER,
              `author` TEXT,
              `title` TEXT,
              `url` TEXT,
              `track_time` TEXT,
              `local_path` TEXT,
              `loaded` INTEGER NOT NULL,
              `position` INTEGER);""", (err)->

    next null

saveParsed = (next)->
  return next() if '--noupdate' in process.argv
  acc = []
  update = 0
  insert = 0
  done = 0
  for track in c.audio.reverse()
    ((t)->
      acc.push (_cbk)->
        db.get "SELECT * FROM track WHERE tid = ?", [+t[1]], (err, doc)->
          if !doc?
            db.run "INSERT INTO track (tid,author,title,url,track_time,local_path, loaded) VALUES (?, ?, ?, ?, ?, ?, ?)", [+t[1], t[5], t[6], t[2], t[4], null, 0], (err, doc)->
              insert++
              _cbk(err)
          else
            if !doc.loaded
              db.run "UPDATE track SET url = ? WHERE tid = ?", [t[2],+t[1]], (err, doc)->
                update++
                _cbk(err)
            else
              done++
              _cbk()
    )(track)
  async.parallel acc, (err)->
    console.info '[__parser__]\n\tupdate:', update, 'insert:', insert, 'done:', done
    console.info '\n\n',('*' for i in [0..100]).join('')
    next(err)

printCount = (next)->
  cache.db.get('select count(*) from track', (err,count)->
      console.info 'count:', count['count(*)']
      next()
    )

_prepareForTrack = (t, next)->
  fold = urlify(t.author)
  file = urlify(t.title)+".mp3"
  filepath = "#{c.dir}/#{fold}/#{file}"
  fs.mkdir "#{c.dir}/#{fold}", (err)->
    fs.unlink filepath, (err)->
      next null, filepath

loadOne = (t, next)->
  timestamp = Date.now()
  _prepareForTrack t, (err, filepath)->
    console.error(err) if err?
    wget.get {url:t.url}, filepath, (err, result)->
      if !err?
        cache.db.run "UPDATE track SET loaded = ?, local_path = ? WHERE tid = ?", [1,filepath,t.tid], (err)->
          time = Date.now() - timestamp
          trackTime = +(t.track_time.replace(':', '.'))
          already += trackTime
          console.info '[__progress__] load time:',time/1000, 'sec. -> progress:', (already/total*100).toFixed(5), '%\ -> left:', (time/trackTime*total/1000/60).toFixed(5), 'min.'
          next err
      else
        console.trace('[__loadOne__] wget error:',err.code)
        next()

loadTracks = (next)->
  acc = []
  db.all 'select * from track where loaded = ?', 0,(err,all)->
    for i in all
      total += +(i.track_time.replace(':', '.'))
    for t in all
      ((track)->
        acc.push (_cbk)-> loadOne track, _cbk
      )(t)
    async.series acc, (err)->
      next err

updatePosition = (next)->
  acc = []
  for i in [1..c.audio.length]
    ((i)->
      acc.push (_cbk)->
        id = +c.audio[i-1][1]
        db.run "UPDATE track SET position = ? WHERE tid = ?", [i, id], (err)-> _cbk(err)
    )(i)
  async.parallel acc, (err)-> 
    console.error(err) if err?
    next()

makeM3u = (next)->
  playlist = "./playlist-#{c.id}.m3u"
  acc = ['#EXTM3U']
  db.all "select * from track where loaded = ? order by position", 1, (err,all)->
    all.reverse()
    for i in all
      acc.push "#EXTINF:#{+(i.track_time.replace(':', '.'))*60},#{i.author} - #{i.title}"
      acc.push path.resolve(i.local_path)
    fs.writeFile playlist, acc.join('\n'), 'utf-8', (err)->
      console.error(err) if err?
      next()


main = ->
  async.waterfall [
    getCred
  , login
  , prepareDirectory
  , parseAudio
  , saveParsed
  , printCount
  , updatePosition
  , loadTracks
  , makeM3u
  ],(err)->   
    db.close()
    console.info 'Done!'
    process.exit 1

main() if not module.parent?



