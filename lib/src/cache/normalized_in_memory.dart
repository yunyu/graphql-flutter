import 'package:meta/meta.dart';

import 'package:graphql_flutter/src/utilities/traverse.dart';
import 'package:graphql_flutter/src/utilities/helpers.dart';
import 'package:graphql_flutter/src/cache/in_memory.dart';
import 'package:graphql_flutter/src/cache/lazy_cache_map.dart';
import 'dart:collection';

typedef DataIdFromObject = String Function(Object node);

class NormalizationException implements Exception {
  NormalizationException(this.cause, this.overflowError, this.value);

  StackOverflowError overflowError;
  String cause;
  Object value;

  String get message => cause;
}

typedef Normalizer = List<String> Function(Object node);

class NormalizedInMemoryCache extends InMemoryCache {
  NormalizedInMemoryCache({
    @required this.dataIdFromObject,
    this.prefix = '@cache/reference',
  });

  DataIdFromObject dataIdFromObject;

  String prefix;

  bool _isReference(Object node) =>
      node is List && node.length == 2 && node[0] == prefix;

  Object _dereference(Object node) {
    if (node is List && _isReference(node)) {
      return read(node[1] as String);
    }

    return null;
  }

  LazyCacheMap lazilyDenormalized(
    Map<String, Object> data, [
    CacheState cacheState,
  ]) {
    return LazyCacheMap(
      data,
      dereference: _dereference,
      cacheState: cacheState,
    );
  }

  Object _denormalizingDereference(Object node) {
    if (node is List && _isReference(node)) {
      return denormalizedRead(node[1] as String);
    }

    return null;
  }

  // TODO ideally cyclical references would be noticed and replaced with null or something
  /// eagerly dereferences all cache references.
  /// *WARNING* if your system allows cyclical references, this will break
  dynamic denormalizedRead(String key) {
    try {
      return traverse(super.read(key), _denormalizingDereference);
    } catch (error) {
      if (error is StackOverflowError) {
        throw NormalizationException(
          '''
          Denormalization failed for $key this is likely caused by a circular reference.
          Please ensure dataIdFromObject returns a unique identifier for all possible entities in your system
          ''',
          error,
          key,
        );
      }
    }
  }

  /*
    Dereferences object references,
    replacing them with cached instances
  */
  @override
  dynamic read(String key) {
    final Object value = super.read(key);
    return value is Map<String, Object> ? lazilyDenormalized(value) : value;
  }

  Normalizer _normalizerFor(Map<String, Object> into) {
    final seenDataIds = HashSet<String>();

    List<String> normalizer(Object node) {
      final String dataId = dataIdFromObject(node);
      if (dataId != null) {
        final dynamic existing = into[dataId];
        // Only write if we haven't previously encountered
        // or there are new keys
        if (!seenDataIds.contains(dataId) ||
            (existing is Map<String, Object> &&
                node is Map<String, Object> &&
                !HashSet.from(existing.keys).containsAll(node.keys))) {
          seenDataIds.add(dataId);
          writeInto(dataId, node, into, normalizer);
        }
        return <String>[prefix, dataId];
      }
      return null;
    }

    return normalizer;
  }

  /// Writes included objects to provided Map,
  /// replacing discernable entities with references
  void writeInto(
    String key,
    Object value,
    Map<String, Object> into, [
    Normalizer normalizer,
  ]) {
    if (value is Map<String, Object>) {
      final Object existing = into[key];
      final Map<String, Object> merged = (existing is Map<String, Object>)
          ? deeplyMergeLeft(<Map<String, Object>>[existing, value])
          : value;

      // normalized the merged value
      into[key] = traverseValues(merged, normalizer ?? _normalizerFor(into));
    } else {
      // writing non-map data to the store is allowed,
      // but there is no merging strategy
      into[key] = value;
    }
  }

  /// Writes included objects to store,
  /// replacing discernable entities with references
  @override
  void write(String key, Object value) {
    writeInto(key, value, data);
  }
}

String typenameDataIdFromObject(Object object) {
  if (object is Map<String, Object> &&
      object.containsKey('__typename') &&
      object.containsKey('id')) {
    return "${object['__typename']}/${object['id']}";
  }
  return null;
}
