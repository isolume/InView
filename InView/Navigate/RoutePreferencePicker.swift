import AccessCore
import SwiftUI

struct RoutePreferencePicker: View {
    @Binding var selection: RoutePreference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Route preference", selection: $selection) {
                ForEach(RoutePreference.allCases, id: \.self) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            Text(selection.detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
