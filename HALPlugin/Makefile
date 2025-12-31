# Makefile for Echo HAL Plugin

PLUGIN_NAME = EchoHAL
BUNDLE_DIR = $(PLUGIN_NAME).driver
INSTALL_DIR = /Library/Audio/Plug-Ins/HAL

# Compiler settings
CXX = clang++
CXXFLAGS = -std=c++17 -O2 -Wall -arch arm64 -arch x86_64
FRAMEWORKS = -framework CoreAudio -framework CoreFoundation -framework AudioToolbox

# Source files
SOURCES = EchoHalPlugin.cpp
OBJECTS = $(SOURCES:.cpp=.o)

# Build targets
all: $(BUNDLE_DIR)

$(BUNDLE_DIR): $(OBJECTS) Info.plist
	@echo "Building HAL plugin bundle..."
	mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(BUNDLE_DIR)/Contents/Resources
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -bundle -o $(BUNDLE_DIR)/Contents/MacOS/$(PLUGIN_NAME) $(OBJECTS)
	cp Info.plist $(BUNDLE_DIR)/Contents/
	@echo "✅ Bundle created: $(BUNDLE_DIR)"

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf $(BUNDLE_DIR)
	rm -f $(OBJECTS)

install: $(BUNDLE_DIR)
	@echo "Installing to $(INSTALL_DIR)..."
	sudo cp -R $(BUNDLE_DIR) $(INSTALL_DIR)/
	sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "✅ Installed and CoreAudio restarted"

uninstall:
	@echo "Uninstalling from $(INSTALL_DIR)..."
	sudo rm -rf $(INSTALL_DIR)/$(BUNDLE_DIR)
	sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "✅ Uninstalled"

.PHONY: all clean install uninstall
