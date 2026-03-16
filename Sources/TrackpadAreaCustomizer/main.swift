import Foundation

let config = Config.parse()
let remapper = ClickRemapper(config: config)
guard remapper.start() else {
    exit(1)
}
RunLoop.current.run()
