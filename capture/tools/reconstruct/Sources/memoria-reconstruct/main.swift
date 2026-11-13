import Foundation
import ReconstructKit

setvbuf(stdout, nil, _IOLBF, 0)
let code = await Runner.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
