APP  := Copy
BUILD := $(PWD)/.build
PRODUCT := $(BUILD)/Build/Products/Debug/$(APP).app

.PHONY: gen build run kill clean release

gen:                    ## 由 project.yml 重新生成 Copy.xcodeproj
	xcodegen generate

build: gen              ## Debug 构建
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug \
	  -derivedDataPath $(BUILD) build | grep -E '(error|warning|BUILD)' || true

run: kill build         ## 构建并启动
	open $(PRODUCT)

kill:                   ## 结束正在运行的实例
	@pkill -x $(APP) 2>/dev/null || true

release: gen            ## Release 构建
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Release \
	  -derivedDataPath $(BUILD) build

clean:
	rm -rf $(BUILD) $(APP).xcodeproj App/Info.generated.plist
