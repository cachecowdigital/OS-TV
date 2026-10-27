import SwiftUI
import IPTVMacCore

struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showFavouritesOnly = false

    private var rows: [Channel] {
        let base = model.visibleChannels
        guard showFavouritesOnly else { return base }
        return base.filter { model.isFavourite($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { channel in
                    Button {
                        model.play(channel)
                    } label: {
                        ChannelRow(channel: channel,
                                   isFavourite: model.isFavourite(channel),
                                   group: model.categoryName(channel.categoryID)) {
                            model.toggleFavourite(channel)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search channels")
            .navigationTitle(showFavouritesOnly ? "Favourites" : "Live TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFavouritesOnly.toggle()
                    } label: {
                        Image(systemName: showFavouritesOnly ? "star.fill" : "star")
                            .foregroundStyle(showFavouritesOnly ? Theme.orange : .primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.categoryFilter = nil
                        } label: {
                            if model.categoryFilter == nil {
                                Label("All channels", systemImage: "checkmark")
                            } else {
                                Text("All channels")
                            }
                        }
                        Divider()
                        ForEach(model.categories) { category in
                            Button {
                                model.categoryFilter = category.id
                            } label: {
                                if model.categoryFilter == category.id {
                                    Label(category.name, systemImage: "checkmark")
                                } else {
                                    Text(category.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(showFavouritesOnly ? "No favourites yet" : "No channels",
                                           systemImage: "tv.slash",
                                           description: Text(showFavouritesOnly
                                                             ? "Tap the star on a channel to keep it here."
                                                             : "No channels match this filter."))
                }
            }
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isFavourite: Bool
    let group: String?
    let onStar: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: channel.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panel)
                    .overlay(Image(systemName: "tv").foregroundStyle(Theme.secondaryText))
            }
            .frame(width: 44, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.subheadline).lineLimit(1)
                if let group { Text(group).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }
            Spacer()
            Button(action: onStar) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .foregroundStyle(isFavourite ? Theme.orange : Theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
