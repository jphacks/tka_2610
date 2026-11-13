import Foundation
import PackKit

setvbuf(stdout, nil, _IOLBF, 0)
exit(Runner.run(arguments: Array(CommandLine.arguments.dropFirst())))
