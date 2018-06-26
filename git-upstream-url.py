#!/usr/bin/python

import xml.etree.ElementTree as ET

root = ET.parse("pom.xml")

namespace = "{http://maven.apache.org/POM/4.0.0}"
scm_connection = root.find("{0}scm/{0}connection".format(namespace)).text

import re

repo_url = re.search("scm:git:(.*)", scm_connection).group(1)
print(repo_url)
