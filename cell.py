#!/usr/bin/env python3
# 
# Generates lua code containing a lookup for the cell name and descriptions.
#
# First run e.g. esmtool --loadcells dump <filename.esm> > output.txt
# Then pass the result to this script.
#
#

import sys
import os

if not(len(sys.argv) == 3):
	print("Usage: cell.py input output")
	sys.exit(0)

cellInputFile = open(sys.argv[1]) # e.g. output.txt
cellInputFile.seek(0)
cellLineData = cellInputFile.readlines()
cellInputFile.close()

codeOutputFile = open(sys.argv[2], 'w')
codeOutputFile.seek(0)
codeOutputFile.write("-- Created with cell.py\n")
codeOutputFile.write("cellDescriptionData = {}\n")

print("Begin processing")

isCell = False
name = ""
loc = ""
region = ""

for line in cellLineData:
	if line.startswith("Record: CELL"): # Cell
		isCell = True
	elif isCell and line.lstrip().startswith("Name: "):
		name = line.lstrip().lstrip("Name: ").rstrip()
	elif isCell and line.lstrip().startswith("Coordinates: "):
		location = line.lstrip().lstrip("Coordinates: ").rstrip()
	elif isCell and line.lstrip().startswith("Region: "):
		region = line.lstrip().lstrip("Region: ").rstrip()
	elif line.lstrip() == "":
		if isCell and not(region == "") and not(name == ""):
			#print("Cell Name: " + name)
			#print("Region: " + region)
			#print("Location: " + location)
			point = location.lstrip("(").rstrip(")").split(",")
			codeOutputFile.write("cellDescriptionData[\"" + point[0] + ", " + point[1] + "\"] = \"" + name + "\"\n")		
	
		isCell = False
		name = ""
		loc = ""
		region = ""

	
print("Done processing")

