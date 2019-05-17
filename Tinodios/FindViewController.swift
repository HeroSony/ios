//
//  FindViewController.swift
//  ios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import UIKit

protocol FindDisplayLogic: class {
    func displayLocalContacts(contacts: [ContactHolder])
    func displayRemoteContacts(contacts: [ContactHolder])
}

class FindViewController: UITableViewController, FindDisplayLogic {
    var interactor: FindBusinessLogic?
    var localContacts: [ContactHolder] = []
    var remoteContacts: [ContactHolder] = []
    var router: FindRoutingLogic?
    var searchController: UISearchController!
    var pendingSearchRequest: DispatchWorkItem? = nil

    private func setup() {
        let viewController = self
        let interactor = FindInteractor()
        let presenter = FindPresenter()
        let router = FindRouter()
        
        viewController.interactor = interactor
        viewController.router = router
        interactor.presenter = presenter
        interactor.router = router
        presenter.viewController = viewController
        router.viewController = viewController

        searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.placeholder = "Search by tags"

        // Make it a-la Telegram UI instead of placing the search bar
        // in the navigation item.
        self.tableView.tableHeaderView = searchController.searchBar

        searchController.delegate = self
        // The default is true.
        searchController.dimsBackgroundDuringPresentation = false
        // Monitor when the search button is tapped.
        searchController.searchBar.delegate = self
        self.definesPresentationContext = true
    }

    func displayLocalContacts(contacts newContacts: [ContactHolder]) {
        self.localContacts = newContacts
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }
    func displayRemoteContacts(contacts newContacts: [ContactHolder]) {
        self.remoteContacts = newContacts
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.setup()
    }
    override func viewDidAppear(_ animated: Bool) {
        self.interactor?.setup()
        self.interactor?.attachToFndTopic()
        self.interactor?.loadAndPresentContacts(searchQuery: nil)
    }
    override func viewDidDisappear(_ animated: Bool) {
        self.interactor?.cleanup()
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return self.localContacts.count
        case 1: return self.remoteContacts.count
        default: return 0
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Local Contacts"
        case 1: return "Directory"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FindTableViewCell", for: indexPath)

        // Configure the cell...
        let contact = indexPath.section == 0 ? localContacts[indexPath.row] : remoteContacts[indexPath.row]
        cell.textLabel?.text = contact.displayName
        cell.detailTextLabel?.text = contact.uniqueId

        return cell
    }
}

extension FindViewController {
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "Find2Messages" {
            // If the search bar is active, deactivate it.
            if searchController.isActive {
                DispatchQueue.main.async {
                    self.searchController.isActive = false
                }
            }
            router?.routeToChat(segue: segue)
        }
    }
}

// MARK: - Search functionality

extension FindViewController: UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {

    private func doSearch(queryString: String?) {
        print("Searching contacts for: \(queryString)")
        self.interactor?.loadAndPresentContacts(searchQuery: queryString)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        pendingSearchRequest?.cancel()
        pendingSearchRequest = nil
        guard let s = getQueryString() else { return }
        doSearch(queryString: s)
    }
    private func getQueryString() -> String? {
        let whitespaceCharacterSet = CharacterSet.whitespaces
        let queryString =
            searchController.searchBar.text!.trimmingCharacters(in: whitespaceCharacterSet)
        return !queryString.isEmpty ? queryString : nil
    }
    func updateSearchResults(for searchController: UISearchController) {
        pendingSearchRequest?.cancel()
        pendingSearchRequest = nil
        let queryString = getQueryString()
        let currentSearchRequest = DispatchWorkItem() {
            self.doSearch(queryString: queryString)
        }
        pendingSearchRequest = currentSearchRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: currentSearchRequest)
    }
    func didDismissSearchController(_ searchController: UISearchController) {
        pendingSearchRequest?.cancel()
        pendingSearchRequest = nil
        self.interactor?.loadAndPresentContacts(searchQuery: nil)
    }
}
