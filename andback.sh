#!/bin/bash
#
# Copyright (C) 2013 Karfield Chen <github@karfield.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
magic='run-as-python ;-)'
"""exec" python -E "$0" "$@" """#$magic"
if __name__ == '__main__':
  import sys
  if sys.argv[-1] == '#%s' % magic:
    del sys.argv[-1]
del magic

import sys,re,os,string,time
import shutil as sh
import subprocess as sub
from optparse import OptionParser
try:
    import xml.etree.cElementTree as xml
except ImportError:
    import xml.etrr.ElementTree as xml
import logging as log
import threading

_topdir = '/tmp'
_xml_db = _topdir + '/devices.xml'

def indent(el, level = 0):
    """
    indent xml text for pretty output
    """
    i = "\n" + level * 2 * " "
    if len(el):
        if not el.text or not el.text.strip():
            el.text = i + 2 * " "
        if not el.tail or not el.tail.strip():
            el.tail = i
        for e in el:
            indent(e, level + 1)
        if e and (not e.tail or not e.tail.strip()):
            e.tail = i
        if not el.tail or not el.tail.strip():
            el.tail = i
    else:
        if level and (not el.tail or not el.tail.strip()):
            el.tail = i

def touch(fn, times = None):
    """ just like 'touch'
    """
    with file(fn, 'a'):
        os.utime(fn, times)
    if os.path.exists(fn):
        return True
    return False

class andbackup(threading.Thread):
    def __init__(self, sn):
        threading.Thread.__init__(self)
        self.serial = sn
        # get attributes from the device
        attr = self.get_attributes()
        # create/retrieve a profile from 'android-device.xml'
        self.create_profile(attr)
        self.cwd = os.chdir(self.workdir)

    def run(self):
        """
        yeap! andbackup is a sub thread, it's can run parallelly
        """
        log.info("start to backup for %s" % self.name)

        dirs = self.adb_shell("ls /sdcard/").read().split()

    def adb_shell(self, cmds):
        p = sub.Popen(['adb', '-s', self.serial, "shell", cmds], stdout = sub.PIPE)
        p.wait()
        return p.stdout

    def get_attributes(self):
        '''
        Get Android device attributes, mainly by 'adb shell getprop', it will
        produce lots of 'ro.*' properties, we use it to recognize different
        device
        '''
        # read from properties
        properties = self.adb_shell('getprop').readlines()

        # scan the contents into dictionaries
        attr = {} # readonly properites
        prop = {} # all properties
        for e in properties:
            m = re.match(r"\[(.*)\]: \[(.*?)\]", e)
            if not m:
                continue
            k = m.group(1)
            v = m.group(2)
            #if (re.match(r"^ro\..*", k)):
            if k.startswith("ro."):
                attr[k[3:]] = v
            prop[k] = v

        # add host name as attribute
        if (prop.has_key('net.hostname')):
            attr['hostname'] = prop['net.hostname']

        attr['serialno'] = self.serial

        # get wifi mac address
        intfs = self.adb_shell("ls /sys/class/net/").readlines()
        if intfs:
            lst = ''
            for i in intfs:
                intf = re.match(r"([\w\d]+).*", i).group(1)
                if intf == "lo":
                    continue
                attr['net.mac.' + intf] = \
                        self.adb_shell("cat /sys/class/net/" + intf +
                                "/address").read()[:-1]
                lst += intf + ','
            attr['net.interfaces'] = lst

        return attr # return attributes list

    def create_profile(self, attr = {}):
        """
        match firstly device according to given attributes which most be interested
        create a xml entry in the 'android_devices.xml' file if none matched
        """
        global _topdir
        try:
            db = xml.parse(_xml_db).getroot()
        except xml.ParseError:
            db = xml.fromstring("<andbackup/>")
        match = False
        for di in db.iter('device'):
            match = True
            for prop in di.iter('property'):
                if attr.has_key(prop.attrib['key']):
                    if attr[prop.attrib['key']].decode('utf-8') != prop.attrib['value']:
                        match = False
                        break
                else:
                    match = False
                    break
            if match:
                break
        ts = time.strftime('%Y/%m/%d %H:%M:%S', time.localtime())

        def update_xmldb():
            if di:
                di.attrib['adate'] = ts
            indent(db)
            xml.ElementTree(db).write(_xml_db, encoding = "UTF-8", xml_declaration = True)

        if match:
            self.name = di.attrib['name']
            self.workdir = os.path.join(_topdir, di.attrib['path'])
            if not os.path.exists(self.workdir):
                os.makedirs(self.workdir)
            update_xmldb()
            return

        # create new profile for this device
        log.info("not matched in local db, create new profile")
        # following 'ro.-' properitis are what we wanted
        store_attrs = ['serialno', 'handware', 'revision',
            'product.manufacturer', 'product.name', 'product.model',
            'product.brand', 'product.device', 'product.local.language',
            'product.local.region', 'build.product', 'build.description',
            'build.id', 'build.display.id', 'build.version.sdk',
            'build.version.codename', 'build.version.release',
            'build.date', 'build.type', 'build.user', 'build.host',
            'build.tags', 'build.fingerprint', 'board.platform',
            'hostname',
            ]
        # generate the device name
        name = "Android"
        ppfx = ""
        if attr.has_key('build.version.sdk'):
            name += {
                    '1': '1.0', '2': '1.1', '3': '1.5',
                    '4': '1.6', # Cupcake
                    '5': '2.0', '6': '2.0.1', # Eclair
                    '7': '2.1', # Eclair
                    '8': '2.2', # Froyo
                    '9': '2.3', '10': '2.3', # Gingerbread
                    '11': '3.0', '12': '3.1', '13': '3.2', # Honeycomb
                    '14': '4.0', '15': '4.0', # Ice Cream Sandwich
                    '16': '4.1', '17': '4.2', # Jelly Bean
                    '18': '5.0', # Key Lime Pie
                    }[attr['build.version.sdk']]
        if attr.has_key('product.manufacturer'):
            name += '_' + attr['product.manufacturer']
        if attr.has_key('product.model'):
            name += '_' + attr['product.model']
            ppfx += '_' + attr['product.model']
        if attr.has_key('serialno'):
            name += '_' + attr['serialno']
            ppfx += '_' + attr['serialno']
        ppfx = ppfx[1:].replace(' ', '_')

        # Name this Android device
        self.name = name.replace(' ', '_')

        for n in range(1, 1000):
            # check the path we wanted, index new one if existed
            path = os.path.join(_topdir, "%s_%d" % (ppfx, n))
            if not os.path.exists(path):
                # make the path for the device
                try:
                    os.makedirs(path)
                except OSError:
                    log.error("fail to makedirs %s" % path)
                    continue
                self.workdir = path
                break

        # generate an xml entry for this device
        di = xml.Element("device", {
            'name': self.name,   # generated name
            'path': os.path.basename(self.workdir),  # the folder to store all backup data
            'cdate': ts,    # create time, first plugin time
            'adate': '',    # last access time
            'mdate': ts     # last modify time
            })
        for st in store_attrs:
            if attr.has_key(st):
                log.debug("append property %s %s" % (st, attr[st]))
                di.append(xml.Element("property", {
                    'key': st,
                    'value': attr[st].decode('utf-8')
                    }))
        db.append(di)
        update_xmldb()

    def scan_dir(self, path, out = None):
        """
        scan directory, build a xml tree for the results
        """
        topdir = path.rstrip('/')
        # android toolbox support 'ls -s -R ' since Eclair(Android-2.1 r1,
        # SDK API Version > 4)
        # before that, we should only use 'ls -l' to figure out...
        # format as '%s %-8s %-8s %d %s %s\n', quoted from:
        # https://android.googlesource.com/platform/system/core/+/android-1.6_r2/toolbox/ls.c
        #
        log.debug("start to list the dir(%s) recursively " % topdir)
        contents = self.adb_shell("ls -s -R " + topdir).readlines()
        log.debug("finished to list this, read as %d lines" % len(contents))
        if not contents:
            return 0
        
        # scan all the contents, convert them into a list that contain one path and
        # one dir entry
        dirs = {}
        dir_list = []
        curf = []
        contents.append('\n') # make last one can be processed
        curd = None
        for ll in contents:
            l = ll.rstrip('\r\n')
            if len(l) < 2:
                if curd:
                    dname = os.path.basename(curd.decode('utf-8'))
                    dx = xml.Element('directory', {'name': dname, 'size': '0'})
                    for f in curf:
                        name = f[1].decode('utf-8')
                        xml.SubElement(dx, 'file', {'name': name, 'size': f[0]})
                    dirs[curd] = dx
                    dir_list.append(curd)
                curf = []
            if l.endswith("No such file or directory") or \
                    l.endswith("Permission denied"):
                curd = None # ignore this dir
                continue
            if l.startswith("total"):
                continue # skip
            m = re.match(r"^([^ ].*):$", l)
            if m:
                curd = m.group(1)
                log.debug("find directory: %s" % curd)
                continue
            dl = l.split()
            for n in range(0, len(dl)/2):
                curf.append((dl[n*2], dl[n*2+1]))
        
        # modify the top one
        top = dirs[topdir]
        top.tag = 'top-dir'
        top.attrib['path'] = topdir
        del top.attrib['name']
        
        # build the relationship on dirs
        for dname in dir_list:
            log.debug("look at %s" % dname)
            if dname == topdir:
                continue # ignore top one
            dx = dirs[dname]
            updir = os.path.dirname(dname)
            if topdir != updir: # not the top
                upper = dirs[updir]
            else:
                upper = top
            for x in upper.iter('file'):
                if x.attrib['name'] == dx.attrib['name']: # remove duplicated
                    upper.remove(x)
                    break
            dx2 = xml.SubElement(upper, 'directory',
                    {'name': dx.attrib['name']})
            totsz = 0
            for x in dx.iter('file'): # FIXME: the fucky ElementTree did not provide
            # 'move' operation, so we only can copy the element to the new dx2
                xml.SubElement(dx2, 'file', {'name': x.attrib['name'],
                    'size': x.attrib['size']})
                totsz += string.atoi(x.attrib['size'])
            dx2.attrib['size'] = "%d" % totsz
            while len(updir) >= len(topdir): # plus size to upper dir recursively
                upper = dirs[updir]
                if upper.attrib.has_key('size'):
                    upper.attrib['size'] = "%d" % (string.atoi(upper.attrib['size']) +
                        totsz)
                else:
                    upper.attrib['size'] = "%d" % totsz
                updir = os.path.dirname(updir)
            dx.clear() # destory the old one
        
        if out:
            # output into the file
            indent(top)
            xml.ElementTree(top).write(os.path.join(out, "file_list.xml"),
                encoding="UTF-8", xml_declaration=True)
        return string.atoi(top.attrib['size'])

    def adb_pull(self, path, out, check = False):
        """
        simplly call 'adb pull to pull something'
        """
        #if not out.startswith("/"): # it is a relative path
        #    out = os.path.join(self.workdir, out) # no need !!! we have chdir
        #    into self.workdir now
        path = path.rstrip('\r\n')
        if check:
            ls = self.adb_shell('ls -l ' + path).readlines()
            if ls[0].endswith("No such file or directory") or \
                    ls[0].endswith("Permission denied"):
                log.error("cannot pull: %s because of it not existed or"\
                        " permission denied")
                return False
            size = 0
            if len(ls) > 1: # what we wanted is a directory
                size = self.scan_dir(path)
            else:
                s = self.adb_shell('ls -s ' + path).read().split()
                size = string.atoi(s[0])
        # make the dir for output
        if not os.path.exists(out):
            log.debug("prepared dir: %s" % out)
            try:
                os.makedirs(out)
            except OSError:
                log.error("failed to prepare '%s' for adb pulling" % out)
                return False
        # chdir to output
        cwd = os.getcwd()
        os.chdir(out)
        log.debug("pulling %s to %s ..." % (path, out))
        p = sub.Popen(['adb', '-s', self.serial, 'pull', path], stderr = sub.PIPE,
                stdout = sub.PIPE)
        p.wait()
        os.chdir(cwd)
        log.debug("finished %s" % p.stdout.read())
        return True

    def adb_backup(self, path):
        """
        backup using 'adb backup', it's not work for most android phones
        """
        p = sub.Popen(['adb', '-s', self.serial, 'backup', '-f', os.path.join(path,
            'adb-backup.ab', '-apk', '-noshared', '-nosystem')], stderr = sub.PIPE,
            stdout = sub.PIPE)
        p.wait()
        log.info("adb back: %s" % p.stdout.read())
        e = p.stderr.read()
        if e:
            log.error("adb back failed(%s)" % e)

if __name__ == "__main__":

    # determine the backup root directory
    if os.environ.has_key('ANDROID_AUTOBACKUP'):
        _topdir = os.environ['ANDROID_AUTOBACKUP']

    opt = OptionParser()
    opt.add_option("-p", "--adb-pull", dest = "src", action = "store",
            type = "string", help = "backup device path directly")
    opt.add_option("-d", "--backup-dir", dest = "workdir", action = "store",
            type = "string", help = "the backup directory")
    opt.add_option("-L", "--log-level", dest = "loglevel", action = "store",
            type = "string", help = "set log output level")
    opt.add_option("-l", "--log-output", dest = "logout", action = "store",
            type = "string", help = "set log output file")
    (opts, args) = opt.parse_args()

    # setup workdir
    if opts.workdir:
        _topdir = opts.workdir
    if not os.path.exists(_topdir):
        try:
            os.makedirs(_topdir)
        except OSError:
            sys.exit()

    # setup log stuff
    loglevel = log.NOTSET
    if opts.loglevel:
        try:
            loglevel = {
                "none": log.NOTSET,
                "debug": log.DEBUG,
                "info": log.INFO,
                "warning": log.WARNING,
                "error": log.ERROR,
                "critical": log.CRITICAL,
                }[string.lower(opts.loglevel)]
        except KeyError:
            loglevel = log.NOTSET
    if opts.logout:
        logout = opts.logout
    else:
        logout = os.path.join(_topdir, "log.txt")
    if touch(logout):
        log.basicConfig(filename = logout,
                format = "<%(levelname)s> %(funcName)s: %(message)s",
                level = loglevel, filemode = "a")

    # touch xml file, make sure it exit
    _xml_db = os.path.join(_topdir, "devices.xml")
    if not touch(_xml_db):
        log.critical("cannot access to %s" % _xml_db)
        sys.exit() # I have not such permission to access

    log.info(80 * ">")
    log.info("start android-backuper on %s" %
            time.strftime('%Y/%m/%d-%H:%M:%S', time.localtime()))

    # use 'adb devices' to check connected devices
    p = sub.Popen(['adb', 'devices'], stdout = sub.PIPE)
    p.wait()
    devs = p.stdout.readlines()

    for d in devs[1:]:
        ll = re.match(r"([\w\d]+)[ \t]*(\w+)", d)
        if not ll:
            continue
        sn = ll.group(1)
        st = ll.group(2)

        if st != "device":
            continue

        # create sub-thread for backuping each device
        ab = andbackup(sn)

        # if you specified some dir to pull directly, run once
        if opts.src:
            log.debug("basename %s" % os.path.basename(opts.src))
            ab.adb_pull(opts.src, "DCIM", check = True) #os.path.basename(opts.src))
            continue

        log.info("start threading backuper ...")
        ab.start()
        ab.join()

    log.info("finished to backup android device(s)")
