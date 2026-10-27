//
//  MapPickerView.swift
//  kgeoScan
//
//  지도에서 스캔 위치를 찍는 뷰 (MapKit). 탭하면 핀이 놓이고, 핀은 끌어서 옮길 수 있다.
//  (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import MapKit
import CoreLocation

struct MapPickerView: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D?
    var initialCenter: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.mapType = .standard
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        let center = coordinate ?? initialCenter ?? CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 300, longitudinalMeters: 300), animated: false)
        context.coordinator.map = map
        if let c = coordinate {
            context.coordinator.place(c, recenter: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if let c = coordinate {
            let current = context.coordinator.annotation?.coordinate
            if current == nil || !MapPickerView.isSame(current!, c) {
                context.coordinator.place(c, recenter: true)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func isSame(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPickerView
        weak var map: MKMapView?
        var annotation: MKPointAnnotation?

        init(_ parent: MapPickerView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = map else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            place(coord, recenter: false)
            parent.coordinate = coord
        }

        func place(_ coord: CLLocationCoordinate2D, recenter: Bool) {
            guard let map = map else { return }
            if let existing = annotation {
                existing.coordinate = coord
            } else {
                let pin = MKPointAnnotation()
                pin.coordinate = coord
                pin.title = "스캔 위치"
                map.addAnnotation(pin)
                annotation = pin
            }
            if recenter {
                map.setCenter(coord, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let identifier = "kgeo.pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.isDraggable = true
            view.canShowCallout = false
            view.markerTintColor = .systemRed
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending || newState == .canceling {
                if let coord = view.annotation?.coordinate {
                    parent.coordinate = coord
                }
                view.dragState = .none
            }
        }
    }
}
