@objc class BottomMenuBuilder: NSObject {
  @objc static func buildMenu(mapViewController: MapViewController,
                              controlsManager: MWMMapViewControlsManager,
                              delegate: BottomMenuDelegate) -> UIViewController {
    BottomMenuBuilder.build(mapViewController: mapViewController,
                            controlsManager: controlsManager,
                            delegate: delegate,
                            sections: [.layers, .items])
  }

  @objc static func buildLayers(mapViewController: MapViewController,
                                controlsManager: MWMMapViewControlsManager,
                                delegate: BottomMenuDelegate) -> UIViewController {
    BottomMenuBuilder.build(mapViewController: mapViewController,
                            controlsManager: controlsManager,
                            delegate: delegate,
                            sections: [.layers])
  }

  @objc static func buildMapTools(mapViewController: MapViewController,
                                  controlsManager: MWMMapViewControlsManager,
                                  delegate: BottomMenuDelegate) -> UIViewController {
    BottomMenuBuilder.build(mapViewController: mapViewController,
                            controlsManager: controlsManager,
                            delegate: delegate,
                            sections: [.mapTools])
  }

  private static func build(mapViewController: MapViewController,
                            controlsManager: MWMMapViewControlsManager,
                            delegate: BottomMenuDelegate,
                            sections: [BottomMenuPresenter.Sections]) -> UIViewController {
    let viewController = BottomMenuViewController(nibName: nil, bundle: nil)
    let interactor = BottomMenuInteractor(viewController: viewController,
                                          mapViewController: mapViewController,
                                          controlsManager: controlsManager,
                                          delegate: delegate)
    let presenter = BottomMenuPresenter(view: viewController, interactor: interactor, sections: sections)
    viewController.presenter = presenter
    // The main menu starts with the map styles cell; the Map tools sheet would start right at its top edge.
    viewController.topPadding = sections.contains(.layers) ? 0 : 12
    return viewController
  }
}
