import 'package:kernel/ast.dart';

// The parameter name contains a randomly generate hex string to avoid collision
// with user generated parameters.
const String _creationLocationParameterName =
    r'$creationLocationd_0dea112b090073317d4';

/// Name of private field added to the Widget class and any other classes that
/// implement Widget.
///
/// Regardless of what library a class implementing Widget is defined in, the
/// private field will always be defined in the context of the widget_inspector
/// library ensuring no name conflicts with regular fields.
const String _locationFieldName = r'isUserCreate';

bool _hasNamedParameter(FunctionNode function, String name) {
  return function.namedParameters
      .any((VariableDeclaration parameter) => parameter.name == name);
}

bool _hasNamedArgument(Arguments arguments, String argumentName) {
  return arguments.named
      .any((NamedExpression argument) => argument.name == argumentName);
}

VariableDeclaration _getNamedParameter(
    FunctionNode function,
    String parameterName,
    ) {
  for (VariableDeclaration parameter in function.namedParameters) {
    if (parameter.name == parameterName) {
      return parameter;
    }
  }
  return null;
}

/// Adds a named parameter to a function if the function does not already have
/// a named parameter with the name or optional positional parameters.
bool _maybeAddNamedParameter(
    FunctionNode function,
    VariableDeclaration variable,
    ) {
  if (_hasNamedParameter(function, _creationLocationParameterName)) {
    // Gracefully handle if this method is called on a function that has already
    // been transformed.
    return false;
  }
  // Function has optional positional parameters so cannot have optional named
  // parameters.
  if (function.requiredParameterCount != function.positionalParameters.length) {
    return false;
  }
  variable.parent = function;
  function.namedParameters.add(variable);
  return true;
}

void _maybeAddCreationLocationArgument(
    Arguments arguments,
    FunctionNode function,
    Expression creationLocation,
    ) {
  if (_hasNamedArgument(arguments, _creationLocationParameterName)) {
    return;
  }
  if (!_hasNamedParameter(function, _creationLocationParameterName)) {
    // TODO(jakemac): We don't apply the transformation to dependencies kernel
    // outlines, so instead we just assume the named parameter exists.
    //
    // The only case in which it shouldn't exist is if the function has optional
    // positional parameters so it cannot have optional named parameters.
    if (function.requiredParameterCount !=
        function.positionalParameters.length) {
      return;
    }
  }

  final NamedExpression namedArgument = NamedExpression(_creationLocationParameterName, creationLocation);
  namedArgument.parent = arguments;
  arguments.named.add(namedArgument);
}

/// Transformer that modifies all calls to Widget constructors to include
/// a [DebugLocation] parameter specifying the location where the constructor
/// call was made.
///
/// This transformer requires that all Widget constructors have already been
/// transformed to have a named parameter with the name specified by
/// `_locationParameterName`.
class _WidgetTransformer extends Transformer {
  /// The [Widget] class defined in the `package:flutter` library.
  ///
  /// Used to perform instanceof checks to determine whether Dart constructor
  /// calls are creating [Widget] objects.
  final Class _widgetClass;

  /// Current factory constructor that node being transformed is inside.
  ///
  /// Used to flow the location passed in as an argument to the factory to the
  /// actual constructor call within the factory.
  Procedure _currentFactory;

  WidgetCreatorTracker _tracker;

  /// Library that contains the transformed call sites.
  ///
  /// The transformation of the call sites is affected by the NNBD opt-in status
  /// of the library.
  Library _currentLibrary;

  _WidgetTransformer(
      {Class widgetClass, WidgetCreatorTracker tracker})
      : _widgetClass = widgetClass,
        _tracker = tracker;


  @override
  Procedure visitProcedure(Procedure node) {
    if (node.isFactory) {
      _currentFactory = node;
      node.transformChildren(this);
      _currentFactory = null;
      return node;
    }
    return defaultTreeNode(node);
  }

  bool _isSubclassOfWidget(Class clazz) {
    return _tracker._isSubclassOf(clazz, _widgetClass);
  }

  @override
  StaticInvocation visitStaticInvocation(StaticInvocation node) {
    node.transformChildren(this);
    final Procedure target = node.target;
    if (!target.isFactory) {
      return node;
    }
    final Class constructedClass = target.enclosingClass;
    if (!_isSubclassOfWidget(constructedClass)) {
      return node;
    }

    _addLocationArgument(node, target.function, constructedClass);
    return node;
  }

  void _addLocationArgument(InvocationExpression node, FunctionNode function,
      Class constructedClass) {
    _maybeAddCreationLocationArgument(
      node.arguments,
      function,
      ConstantExpression(BoolConstant(_computeLocation(node, function, constructedClass))),
    );
  }

  @override
  ConstructorInvocation visitConstructorInvocation(ConstructorInvocation node) {
    node.transformChildren(this);

    final Constructor constructor = node.target;
    final Class constructedClass = constructor.enclosingClass;
    if (!_isSubclassOfWidget(constructedClass)) {
      return node;
    }

    _addLocationArgument(node, constructor.function, constructedClass);
    return node;
  }

  bool _computeLocation(InvocationExpression node, FunctionNode function,
      Class constructedClass) {
    if (_currentFactory != null &&
        _tracker._isSubclassOf(constructedClass, _currentFactory.enclosingClass)) {

      final VariableDeclaration creationLocationParameter =
      _getNamedParameter(_currentFactory.function, _creationLocationParameterName);
      if (creationLocationParameter != null) {
        return false;
      }
    }
    return !node.location.file.toString().contains('packages/flutter/');
  }

  void enterLibrary(Library library) {
    assert(
        _currentLibrary == null,
        "Attempting to enter library '${library.fileUri}' "
        "without having exited library '${_currentLibrary.fileUri}'.");
    _currentLibrary = library;
  }

  void exitLibrary() {
    assert(_currentLibrary != null,
        "Attempting to exit a library without having entered one.");
    _currentLibrary = null;
  }
}

/// Rewrites all widget constructors and constructor invocations to add a
/// parameter specifying the location the constructor was called from.
///
/// The creation location is stored as a private field named `_location`
/// on the base widget class and flowed through the constructors using a named
/// parameter.
class WidgetCreatorTracker {
  Class _widgetClass;

  /// Marker interface indicating that a private _location field is
  /// available.
  Class _hasCreationLocationClass;

  void _resolveFlutterClasses(Iterable<Library> libraries) {
    // If the Widget or Debug location classes have been updated we need to get
    // the latest version
    for (Library library in libraries) {
      final Uri importUri = library.importUri;
      if (importUri != null && importUri.scheme == 'package') {
        if (importUri.path == 'flutter/src/widgets/framework.dart' ||
            importUri.path == 'flutter_web/src/widgets/framework.dart') {
          for (Class class_ in library.classes) {
            if (class_.name == 'Widget') {
              _widgetClass = class_;
            }
          }
        } else {
          if (importUri.path == 'flutter_module/widget/user_widget.dart') {
            for (Class class_ in library.classes) {
              if (class_.name == 'UserWidget') {
                _hasCreationLocationClass = class_;
              }
            }
          }
        }
      }
    }
    print('widget class is : $_widgetClass');
    print('user class is : $_hasCreationLocationClass');
  }



  /// Modify [clazz] to add a field named [_locationFieldName] that is the
  /// first parameter of all constructors of the class.
  ///
  /// This method should only be called for classes that implement but do not
  /// extend [Widget].
  void _transformClassImplementingWidget(
      Class clazz, Object changedStructureNotifier) {
    if (clazz.fields
        .any((Field field) => field.name.name == _locationFieldName)) {
      // This class has already been transformed. Skip
      return;
    }
    clazz.implementedTypes
        .add(Supertype(_hasCreationLocationClass, <DartType>[]));
    // changedStructureNotifier?.registerClassHierarchyChange(clazz);

    // We intentionally use the library context of the _HasCreationLocation
    // class for the private field even if [clazz] is in a different library
    // so that all classes implementing Widget behave consistently.
    final Name fieldName = Name(
      _locationFieldName,
      _hasCreationLocationClass.enclosingLibrary,
    );
    final Field locationField = Field(fieldName,
        type: const DynamicType(),
        isFinal: true,
        reference: clazz.reference.canonicalName
            ?.getChildFromFieldWithName(fieldName)
            ?.reference);
    clazz.addMember(locationField);

    print('class is : $clazz');
    print('location field is : ${locationField.toString()}');

    final Set<Constructor> _handledConstructors = Set<Constructor>.identity();

    void handleConstructor(Constructor constructor) {
      if (!_handledConstructors.add(constructor)) {
        return;
      }
      assert(!_hasNamedParameter(
        constructor.function,
        _creationLocationParameterName,
      ));
      final VariableDeclaration variable = VariableDeclaration(
        _creationLocationParameterName,
        type: const DynamicType(),
      );
      if (!_maybeAddNamedParameter(constructor.function, variable)) {
        return;
      }

      bool hasRedirectingInitializer = false;
      for (Initializer initializer in constructor.initializers) {
        if (initializer is RedirectingInitializer) {
          if (initializer.target.enclosingClass == clazz) {
            // We need to handle this constructor first or the call to
            // addDebugLocationArgument bellow will fail due to the named
            // parameter not yet existing on the constructor.
            handleConstructor(initializer.target);
          }
          _maybeAddCreationLocationArgument(
            initializer.arguments,
            initializer.target.function,
            VariableGet(variable),
          );
          hasRedirectingInitializer = true;
          break;
        }
      }
      if (!hasRedirectingInitializer) {
        constructor.initializers.add(FieldInitializer(
          locationField, VariableGet(variable),
        ));
      }
    }

    // Add named parameters to all constructors.
    clazz.constructors.forEach(handleConstructor);
  }

  /// Transform the given [libraries].
  ///
  /// The libraries from [module] is searched for the Widget class,
  /// the _Location class and the _HasCreationLocation class.
  /// If the component does not contain them, the ones from a previous run is
  /// used (if any), otherwise no transformation is performed.
  ///
  /// Upon transformation the [changedStructureNotifier] (if provided) is used
  /// to notify the listener that  that class hierarchy of certain classes has
  /// changed. This is neccesary for instance when doing an incremental
  /// compilation where the class hierarchy is kept between compiles and thus
  /// has to be kept up to date.
  void transform(Component module, List<Library> libraries,
      Object changedStructureNotifier) {
    print('==start ==== : ${libraries.length}');
    if (libraries.isEmpty) {
      return;
    }

    _resolveFlutterClasses(module.libraries);

    if (_widgetClass == null) {
      // This application doesn't actually use the package:flutter library.
      return;
    }

    final Set<Class> transformedClasses = Set<Class>.identity();
    final Set<Library> librariesToTransform = Set<Library>.identity()
      ..addAll(libraries);

    for (Library library in libraries) {
      for (Class class_ in library.classes) {
        _transformWidgetConstructors(
          librariesToTransform,
          transformedClasses,
          class_,
          changedStructureNotifier,
        );
      }
    }

    // Transform call sites to pass the location parameter.
    final _WidgetTransformer callsiteTransformer =
        _WidgetTransformer(
            widgetClass: _widgetClass,
            tracker: this);

    for (Library library in libraries) {
      callsiteTransformer.enterLibrary(library);
      library.transformChildren(callsiteTransformer);
      callsiteTransformer.exitLibrary();
    }
  }

  bool _isSubclassOfWidget(Class clazz) => _isSubclassOf(clazz, _widgetClass);

  bool _isSubclassOf(Class a, Class b) {
    // TODO(askesc): Cache results.
    // TODO(askesc): Test for subtype rather than subclass.
    Class current = a;
    while (current != null) {
      if (current == b) return true;
      current = current.superclass;
    }
    return false;
  }

  void _transformWidgetConstructors(
      Set<Library> librariesToBeTransformed,
      Set<Class> transformedClasses,
      Class clazz,
      Object changedStructureNotifier) {
    if (!_isSubclassOfWidget(clazz) ||
        !librariesToBeTransformed.contains(clazz.enclosingLibrary) ||
        !transformedClasses.add(clazz)) {
      return;
    }

    // Ensure super classes have been transformed before this class.
    if (clazz.superclass != null &&
        !transformedClasses.contains(clazz.superclass)) {
      _transformWidgetConstructors(
        librariesToBeTransformed,
        transformedClasses,
        clazz.superclass,
        changedStructureNotifier,
      );
    }

    for (Procedure procedure in clazz.procedures) {
      if (procedure.isFactory) {
        _maybeAddNamedParameter(
          procedure.function,
          VariableDeclaration(_creationLocationParameterName,
              type: const DynamicType(),
              isRequired: clazz.enclosingLibrary.isNonNullableByDefault),
        );
      }
    }

    // Handle the widget class and classes that implement but do not extend the
    // widget class.
    if (!_isSubclassOfWidget(clazz.superclass)) {
      _transformClassImplementingWidget(clazz, changedStructureNotifier);
      return;
    }

    final Set<Constructor> _handledConstructors =
        Set<Constructor>.identity();

    void handleConstructor(Constructor constructor) {
      if (!_handledConstructors.add(constructor)) {
        return;
      }

      final VariableDeclaration variable = VariableDeclaration(
          _creationLocationParameterName,
          type: const DynamicType(),
          isRequired: clazz.enclosingLibrary.isNonNullableByDefault);
      if (_hasNamedParameter(
          constructor.function, _creationLocationParameterName)) {
        return;
      }
      if (!_maybeAddNamedParameter(constructor.function, variable)) {
        return;
      }
      for (Initializer initializer in constructor.initializers) {
        if (initializer is RedirectingInitializer) {
          if (initializer.target.enclosingClass == clazz) {
            // We need to handle this constructor first or the call to
            // addDebugLocationArgument could fail due to the named parameter
            // not existing.
            handleConstructor(initializer.target);
          }

          _maybeAddCreationLocationArgument(
            initializer.arguments,
            initializer.target.function,
            VariableGet(variable),
          );
        } else if (initializer is SuperInitializer &&
            _isSubclassOfWidget(initializer.target.enclosingClass)) {
          _maybeAddCreationLocationArgument(
            initializer.arguments,
            initializer.target.function,
            VariableGet(variable),
          );
        }
      }
    }

    clazz.constructors.forEach(handleConstructor);
  }
}
