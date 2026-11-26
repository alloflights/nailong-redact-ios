import SwiftUI

#if os(iOS)
@main
struct NailongRedactApp: App {
    @StateObject private var vm = RedactStudioViewModel()

    var body: some Scene {
        WindowGroup {
            iPhoneAppView(vm: vm)
                .onOpenURL { url in
                    vm.importImage(from: url)
                }
        }
    }
}
#endif

struct iPhoneAppView_Previews: PreviewProvider {
    static var previews: some View {
        iPhoneAppView(vm: RedactStudioViewModel())
    }
}
